package main

import (
	"bufio"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	manager        = "Opkg::Manager"
	optDirectory   = "/opt/"
	defaultInitrc  = "/opt/etc/initrc"
	defaultScripts = "/opt/etc/init.d/"
	scriptPath     = "/opt/bin:/opt/sbin:/opt/usr/bin:/opt/usr/sbin:/bin:/sbin:/usr/bin:/usr/sbin"
	scriptLibs     = "/opt/lib:/opt/usr/lib:/lib:/usr/lib"
	startLimit     = 120 * time.Second
	hookLimit      = 24 * time.Second
)

const (
	statusIdle = iota
	statusStarted
	statusNoDisk
	statusMountFailed
	statusBindFailed
	statusNoScripts
	statusNotStarted
	statusExitCode
	statusTimedOut
)

var statusNames = map[int]string{
	statusIdle:        "opkg disk was never set",
	statusStarted:     "initrc started",
	statusNoDisk:      "disk not found",
	statusMountFailed: "filesystem mount failed",
	statusBindFailed:  "opkg mount failed",
	statusNoScripts:   "no initrc or init.d script ran",
	statusNotStarted:  "initrc failed to start",
	statusExitCode:    "initrc returned a non-zero exit code",
	statusTimedOut:    "initrc timed out",
}

type opkg struct {
	chroot        bool
	disk          string
	initrc        string
	mounted       bool
	mountPoint    string
	device        string
	status        int
	manualDevices bool
	diskWait      time.Duration
	unpacker      string
}

func (o *opkg) root() string {
	if o.chroot {
		return optDirectory
	}
	return ""
}

func (o *opkg) initrcPath() string {
	if o.initrc != "" {
		return o.initrc
	}
	return defaultInitrc
}

func mountLogged(source, target, fstype string, flags uintptr, data string) error {
	if err := syscall.Mount(source, target, fstype, flags, data); err != nil {
		return err
	}
	ndmLog(levelInfo, manager, "%1 mounted to %2", source, target)
	return nil
}

func (o *opkg) setDisk(name, link string) {
	if o.mounted {
		o.unmount()
	}
	o.disk = strings.TrimSuffix(strings.TrimSuffix(name, "/"), ":")
	deadline := time.Now().Add(o.diskWait)
	var found partition
	for {
		var ok bool
		if found, ok = findPartition(o.disk, o.manualDevices); ok || time.Now().After(deadline) {
			if !ok {
				emuLog(levelError, "no partition with label or UUID %q", o.disk)
				o.status = statusNoDisk
				return
			}
			break
		}
		time.Sleep(200 * time.Millisecond)
	}
	o.device = found.device
	o.mountPoint = "/tmp/mnt/" + found.uuid
	_ = os.MkdirAll(o.mountPoint, 0o755)
	if !o.isMountPoint(o.mountPoint) {
		flags := uintptr(syscall.MS_NOSUID | syscall.MS_NODEV | syscall.MS_NOEXEC | syscall.MS_NOATIME)
		if err := syscall.Mount(found.device, o.mountPoint, "ext4", flags, ""); err != nil {
			emuLog(levelError, "unable to mount %s (label %q) on %s as ext4: %s", found.device, found.label, o.mountPoint, errorString(err))
			o.status = statusMountFailed
			return
		}
		emuLog(levelInfo, "%s (label %q) mounted on %s", found.device, found.label, o.mountPoint)
	}
	if !o.initialize(link) {
		o.status = statusBindFailed
		return
	}
	o.mounted = true
	o.startInitrc()
}

func (o *opkg) isMountPoint(target string) bool {
	mounts, _ := readMounts()
	for _, entry := range mounts {
		if entry.target == target {
			return true
		}
	}
	return false
}

func (o *opkg) alreadyMounted() bool {
	mounts, err := readMounts()
	if err != nil {
		ndmFail(manager, 0xcffd0146, "")
		return true
	}
	diskSeen, optSeen := false, false
	for _, entry := range mounts {
		if !strings.Contains(entry.options, "rw") {
			continue
		}
		if strings.Contains(entry.target, optDirectory) {
			optSeen = true
		} else if strings.Contains(entry.target, o.mountPoint) {
			diskSeen = true
		}
	}
	return diskSeen && optSeen
}

func (o *opkg) remount() bool {
	mounts, _ := readMounts()
	options := map[string]string{}
	var order []string
	for _, entry := range mounts {
		if _, known := options[entry.target]; !known {
			order = append(order, entry.target)
		}
		options[entry.target] = entry.options
	}
	best := ""
	for _, target := range order {
		if len(target) > 1 && strings.HasPrefix(o.mountPoint, target) && len(target) > len(best) {
			best = target
		}
	}
	if best == "" {
		ndmLog(levelInfo, manager, "mount point is not found")
		return true
	}
	var kept []string
	for _, option := range strings.Split(options[best], ",") {
		switch option {
		case "nodev", "noexec", "nosuid", "rw", "relatime", "noatime":
		default:
			kept = append(kept, option)
		}
	}
	if err := mountLogged(best, best, "", syscall.MS_REMOUNT, strings.Join(kept, ",")); err != nil {
		ndmLog(levelWarn, manager, "failed to remount %1: %2", best, errorString(err))
		return false
	}
	return true
}

func createDirectory(name string, recursive bool) bool {
	if access(name) {
		return true
	}
	if recursive {
		return os.MkdirAll(name, 0o755) == nil
	}
	return syscall.Mkdir(strings.TrimSuffix(name, "/"), 0o755) == nil
}

func copyFile(source, target string) bool {
	input, inputErr := os.Open(source)
	if inputErr != nil {
		ndmLog(levelError, "Io::File", `unable to open "%1": %2`, source, errorString(inputErr))
	}
	output, outputErr := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if outputErr != nil {
		ndmLog(levelError, "Io::File", `unable to open "%1": %2`, target, errorString(outputErr))
	}
	ok := inputErr == nil && outputErr == nil
	if ok {
		_, err := io.Copy(output, input)
		ok = err == nil
	}
	if input != nil {
		_ = input.Close()
	}
	if output != nil {
		if output.Close() != nil {
			ok = false
		}
	}
	if ok && syscall.Access(source, 1) == nil {
		if info, err := os.Stat(target); err == nil {
			_ = os.Chmod(target, info.Mode().Perm()|0o111)
		}
	}
	return ok
}

func (o *opkg) prepareChroot() {
	created := true
	for _, directory := range []string{"/opt/proc/", "/opt/sys/", "/opt/dev/", "/opt/tmp"} {
		if !createDirectory(directory, false) {
			created = false
			break
		}
	}
	if created {
		created = createDirectory("/opt/lib/system-modules/", true)
	}
	if !created {
		ndmFail(manager, 0xcffd0452, "")
	}
	if err := mountLogged("none", "/opt/proc/", "proc", 0, ""); err != nil {
		ndmFail(manager, 0xcffd0457, "unable to mount %1: %2", "/opt/proc/", errorString(err))
	}
	if err := mountLogged("none", "/opt/sys/", "sysfs", 0, ""); err != nil {
		ndmFail(manager, 0xcffd045d, "unable to mount %1: %2", "/opt/sys/", errorString(err))
	}
	if err := mountLogged("/dev", "/opt/dev/", "", syscall.MS_BIND, ""); err != nil {
		ndmFail(manager, 0xcffd0463, "unable to mount --bind %1 to %2: %3", "/dev", "/opt/dev/", errorString(err))
	}
	if err := mountLogged("/tmp", "/opt/tmp", "", syscall.MS_BIND, ""); err != nil {
		ndmFail(manager, 0xcffd0469, "unable to mount --bind %1 to %2: %3", "/tmp", "/opt/tmp", errorString(err))
	}
	if err := mountLogged("/lib/modules", "/opt/lib/system-modules/", "", syscall.MS_BIND, ""); err != nil {
		ndmFail(manager, 0xcffd046f, "unable to mount --bind %1 to %2: %3", "/lib/modules", "/opt/lib/system-modules/", errorString(err))
	}
	if err := mountLogged("none", "/opt/dev/pts/", "devpts", 0, ""); err != nil {
		ndmFail(manager, 0xcffd0475, "unable to mount %1 to %2: %3", "none", "/opt/dev/pts/", errorString(err))
	}
	links := []struct {
		target string
		name   string
		code   uint32
	}{
		{"/tmp/passwd", "/opt/etc/passwd", 0xcffd047c},
		{"/tmp/group", "/opt/etc/group", 0xcffd0482},
		{".", "/opt/opt", 0xcffd0488},
	}
	for _, link := range links {
		if !access(link.name) && os.Symlink(link.target, link.name) != nil {
			ndmFail(manager, link.code, "")
		}
	}
	copies := []struct {
		source string
		target string
		code   uint32
	}{
		{"/etc/shells", "/opt/etc/shells", 0xcffd048e},
		{"/etc/profile", "/opt/etc/profile", 0xcffd0496},
	}
	for _, item := range copies {
		if !access(item.target) && !copyFile(item.source, item.target) {
			ndmFail(manager, item.code, "unable to copy %1 -> %2", item.source, item.target)
		}
	}
}

func (o *opkg) initialize(link string) bool {
	if !o.alreadyMounted() {
		if !o.remount() {
			return false
		}
		if err := mountLogged(o.mountPoint, optDirectory, "", syscall.MS_BIND, ""); err != nil {
			ndmLog(levelWarn, manager, "failed to mount --bind %1 to %2: %3", o.mountPoint, optDirectory, errorString(err))
			return false
		}
	}
	if o.chroot {
		o.prepareChroot()
	}
	if link != "" && o.download(link) < 0 {
		ndmFail(manager, 0xcffd04a5, "")
	}
	if o.install() {
		ndmLog(levelInfo, manager, "%1 initialized", o.mountPoint)
	}
	return true
}

func (o *opkg) download(link string) int {
	const directory = "/opt/install/"
	if !access(directory) && syscall.Mkdir("/opt/install", 0o755) != nil {
		ndmFail(manager, 0xcffd027b, "")
		return -1
	}
	token := make([]byte, 8)
	_, _ = rand.Read(token)
	name := directory + hex.EncodeToString(token) + ".tar.gz"
	output, err := os.OpenFile(name, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		ndmLog(levelError, "Io::File", `unable to open "%1": %2`, name, errorString(err))
		ndmFail(manager, 0xcffd028e, "")
		return -1
	}
	defer func() { _ = output.Close() }()
	parsed, err := url.Parse(link)
	if err != nil || parsed.Host == "" {
		ndmFail(manager, 0xcffe0296, "")
		return -1
	}
	if !strings.HasSuffix(parsed.Path, "tar.gz") && !strings.HasSuffix(parsed.Path, "tgz") {
		ndmFail(manager, 0xcffd029c, "only TAR/GZIP files are supported")
		return -1
	}
	ndmLog(levelInfo, manager, `downloading installer from "%1" to "%2"`, link, name)
	port := parsed.Port()
	secure := parsed.Scheme == "https"
	if port == "" {
		port = "80"
		if secure {
			port = "443"
		}
	} else if _, err := strconv.ParseUint(port, 10, 16); err != nil {
		ndmFail(manager, 0xcffd02b4, `invalid port: "%1"`, port)
		return -1
	}
	var connection net.Conn
	connection, err = net.DialTimeout("tcp", net.JoinHostPort(parsed.Hostname(), port), 15*time.Second)
	if err == nil && secure {
		connection = tls.Client(connection, &tls.Config{InsecureSkipVerify: true, ServerName: parsed.Hostname()})
	}
	if err != nil {
		ndmFail(manager, 0xcffd02e1, "unable to make HTTP request")
		return -1
	}
	defer func() { _ = connection.Close() }()
	request := parsed.RequestURI()
	_, err = fmt.Fprintf(connection, "GET %s HTTP/1.0\r\nHost: %s\r\nUser-Agent: ndm\r\nConnection: close\r\n\r\n", request, parsed.Host)
	reader := bufio.NewReader(connection)
	var statusLine string
	if err == nil {
		statusLine, err = reader.ReadString('\n')
	}
	fields := strings.SplitN(strings.TrimSpace(statusLine), " ", 3)
	if err != nil || len(fields) < 2 {
		ndmFail(manager, 0xcffd02e1, "unable to make HTTP request")
		return -1
	}
	reason := ""
	if len(fields) == 3 {
		reason = fields[2]
	}
	gzipped := false
	for {
		header, err := reader.ReadString('\n')
		if err != nil || strings.TrimSpace(header) == "" {
			break
		}
		key, value, _ := strings.Cut(header, ":")
		key, value = strings.ToLower(strings.TrimSpace(key)), strings.ToLower(strings.TrimSpace(value))
		switch {
		case key == "content-type" && (strings.HasPrefix(value, "application/gzip") || strings.HasPrefix(value, "application/x-gzip")):
			gzipped = true
		case key == "content-encoding" && strings.Contains(value, "gzip"):
			gzipped = true
		}
	}
	if gzipped {
		ndmFail("Io::Http::Client", 0xcffd02e7, "")
		ndmFail(manager, 0xcffd02e1, "unable to make HTTP request")
		return -1
	}
	ndmLog(levelInfo, manager, "response code %1 (%2)", fields[1], reason)
	if fields[1] != "200" {
		ndmFail(manager, 0xcffd02ea, "invalid response")
		return -1
	}
	buffer := make([]byte, 0x4000)
	total, reported := int64(0), int64(0)
	for {
		count, readErr := reader.Read(buffer)
		if count > 0 {
			if _, err := output.Write(buffer[:count]); err != nil {
				ndmFail(manager, 0xcffd0306, "unable to download: %1", errorString(err))
				return -1
			}
			total += int64(count)
			if total>>20 != reported {
				reported = total >> 20
				ndmLog(levelInfo, manager, "downloaded %1 MiB", reported)
			}
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			ndmFail(manager, 0xcffd0311, "stream error: %1", errorString(readErr))
			return -1
		}
	}
	ndmLog(levelInfo, manager, "download completed")
	return 0
}

func (o *opkg) install() bool {
	const directory = "/opt/install/"
	if !access(directory) || !isDirectory(directory) {
		return true
	}
	if o.unpacker == "builtin" {
		if !unpackArchives(directory, optDirectory) {
			return false
		}
	} else {
		result := runProcess("Opkg install", "npkg", []string{"-i", directory, "-o", optDirectory}, os.Environ(), "", startLimit, func(text string) {
			if printable(text) {
				logbook.write(levelInfo, "npkg", text)
			}
		})
		switch {
		case !result.started:
			ndmFail(manager, 0xcffd0347, "exit code %1", 0)
			return false
		case result.timedOut:
			ndmFail(manager, 0xcffd0344, "timed out")
			return false
		case result.exitCode != 0:
			ndmFail(manager, 0xcffd0347, "exit code %1", result.exitCode)
			return false
		}
	}
	entries, err := os.ReadDir(directory)
	if err != nil {
		ndmFail(manager, 0xcffd034d, "")
		return false
	}
	for _, entry := range entries {
		if !entry.IsDir() {
			_ = os.Remove(directory + entry.Name())
		}
	}
	_ = syscall.Rmdir("/opt/install")
	return true
}

func (o *opkg) startInitrc() {
	configured := o.initrcPath()
	target := ""
	resolved, err := realPath(configured)
	switch {
	case err != nil:
		ndmLog(levelInfo, manager, `missing initrc "%1": %2, trying default one (%3)`, configured, errorString(err), defaultScripts)
	case !strings.HasPrefix(resolved, optDirectory):
		ndmLog(levelInfo, manager, `missing initrc "%1": %2, trying default one (%3)`, configured, "not in /opt", defaultScripts)
	default:
		target = resolved
	}
	if target == "" {
		target = defaultScripts
	}
	emuLog(levelInfo, "running %s start, uptime %s s", target, uptime())
	outcome := o.execScripts(target, "start", nil, startLimit)
	switch {
	case outcome.total == 0:
		o.status = statusNoScripts
	case outcome.notStarted > 0:
		o.status = statusNotStarted
	case outcome.timedOut > 0:
		o.status = statusTimedOut
	case outcome.failed > 0:
		o.status = statusExitCode
	default:
		o.status = statusStarted
	}
	emuLog(levelInfo, "initrc finished: %s, uptime %s s", statusNames[o.status], uptime())
}

type scriptOutcome struct {
	total      int
	succeeded  int
	failed     int
	timedOut   int
	notStarted int
}

func (o *opkg) execScripts(location, action string, variables []string, limit time.Duration) scriptOutcome {
	var outcome scriptOutcome
	if location == "" {
		ndmFail(manager, 0xcffd0190, "")
		return outcome
	}
	var scripts []string
	if access(location) {
		if !isDirectory(location) {
			scripts = []string{location}
		} else {
			entries, err := os.ReadDir(location)
			if err != nil {
				ndmFail(manager, 0xcffd019c, "")
				return outcome
			}
			var names []string
			for _, entry := range entries {
				if !strings.HasPrefix(entry.Name(), ".") {
					names = append(names, entry.Name())
				}
			}
			sort.Strings(names)
			prefix := location
			if !strings.HasSuffix(prefix, "/") {
				prefix += "/"
			}
			for _, name := range names {
				scripts = append(scripts, prefix+name)
			}
		}
	}
	root := o.root()
	for _, entry := range scripts {
		if isDirectory(entry) {
			continue
		}
		outcome.total++
		script := entry
		if root != "" && isSymlink(entry) {
			target, err := os.Readlink(entry)
			if err != nil {
				ndmLog(levelWarn, manager, `unable to read symlink "%1": %2`, entry, errorString(err))
			}
			if !access(target) {
				script = strings.TrimSuffix(root, "/") + target
			}
		}
		file, err := os.Open(script)
		if err != nil {
			ndmLog(levelWarn, manager, "unable to open file: %1", script)
			outcome.notStarted++
			continue
		}
		first, _ := bufio.NewReaderSize(file, 0x1000).ReadString('\n')
		_ = file.Close()
		first = strings.TrimRight(first, "\r\n")
		interpreter := "/opt/bin/sh"
		var arguments []string
		if strings.HasPrefix(first, "#!") {
			words := strings.Fields(first)
			interpreter = words[0][2:]
			arguments = words[1:]
			if !strings.HasPrefix(interpreter, "/opt") {
				interpreter = "/opt" + interpreter
			}
		}
		arguments = append(append([]string{}, arguments...), script, action)
		environment := append(append([]string{}, variables...), "PATH="+scriptPath, "LD_LIBRARY_PATH="+scriptLibs)
		result := runProcess("Opkg shell", interpreter, arguments, environment, root, limit, func(text string) {
			if printable(text) {
				ndmLog(levelInfo, manager, "%1: %2", script, text)
			}
		})
		switch {
		case !result.started:
			ndmLog(levelWarn, manager, "process %1: failed to start", script)
			outcome.notStarted++
		case result.timedOut:
			ndmLog(levelWarn, manager, "%1: timed out", script)
			outcome.timedOut++
		case result.exitCode != 0:
			ndmLog(levelWarn, manager, "%1: exit code %2", script, result.exitCode)
			outcome.failed++
		default:
			outcome.succeeded++
		}
	}
	return outcome
}

func (o *opkg) killAll() {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		ndmFail(manager, 0xcffd039b, "")
		return
	}
	for _, entry := range entries {
		link := "/proc/" + entry.Name() + "/exe"
		if !access(link) {
			continue
		}
		target, err := os.Readlink(link)
		if err != nil || !strings.HasPrefix(target, optDirectory) {
			continue
		}
		if pid, err := strconv.Atoi(entry.Name()); err == nil {
			_ = syscall.Kill(pid, syscall.SIGTERM)
		}
	}
	for _, target := range []string{"/opt/sys/", "/opt/proc/", "/opt/dev/", "/opt/tmp", "/opt/lib/system-modules/"} {
		_ = syscall.Unmount(target, syscall.MNT_DETACH)
	}
}

func (o *opkg) unmount() {
	o.execScripts(o.initrcPath(), "stop", nil, hookLimit)
	o.killAll()
	if err := syscall.Unmount(optDirectory, syscall.MNT_DETACH); err != nil {
		ndmLog(levelWarn, manager, "unmount failed: %1", errorString(err))
	} else {
		ndmLog(levelInfo, manager, "disk unmounted")
	}
	o.mounted = false
}

func (o *opkg) setChroot(enabled bool) {
	if o.chroot != enabled {
		o.killAll()
		o.chroot = enabled
		if o.mounted {
			if o.initialize("") {
				o.startInitrc()
			}
		}
	}
	state := "disabled"
	if enabled {
		state = "enabled"
	}
	ndmLog(levelInfo, manager, "chroot %1", state)
}

func (o *opkg) hook(name string, variables []string) (scriptOutcome, bool) {
	if !o.mounted {
		return scriptOutcome{}, false
	}
	return o.execScripts("/opt/etc/ndm/"+name+".d/", "hook", variables, hookLimit), true
}

func (o *opkg) release() {
	if o.mounted {
		o.unmount()
	}
	if o.mountPoint != "" {
		syscall.Sync()
		if err := syscall.Unmount(o.mountPoint, 0); err != nil {
			emuLog(levelWarn, "unable to unmount %s: %s", o.mountPoint, errorString(err))
		}
	}
}
