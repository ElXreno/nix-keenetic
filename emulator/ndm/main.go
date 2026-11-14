package main

import (
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func mustMount(source, target, fstype string, flags uintptr, data string) {
	if err := syscall.Mount(source, target, fstype, flags, data); err != nil {
		fmt.Printf("ndm: mount %s on %s: %s\r\n", source, target, err)
	}
}

func halt(reason string) {
	fmt.Printf("ndm: fatal: %s\r\n", reason)
	fmt.Printf("[C] ndm: Emulator: exit status 1 (%s).\r\n", reason)
	syscall.Sync()
	time.Sleep(200 * time.Millisecond)
	_ = syscall.Reboot(syscall.LINUX_REBOOT_CMD_POWER_OFF)
	select {}
}

func attachConsole() {
	console, err := os.OpenFile("/dev/console", os.O_RDWR, 0)
	if err != nil {
		return
	}
	for descriptor := 0; descriptor < 3; descriptor++ {
		_ = syscall.Dup3(int(console.Fd()), descriptor, 0)
	}
	_ = console.Close()
}

func uptime() string {
	data, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return "?"
	}
	return strings.Fields(string(data))[0]
}

func bootstrap() (map[string]string, bool) {
	for _, directory := range []string{"/dev", "/proc", "/sys", "/newroot"} {
		_ = os.MkdirAll(directory, 0o755)
	}
	_ = syscall.Mount("proc", "/proc", "proc", 0, "")
	_ = syscall.Mount("sysfs", "/sys", "sysfs", 0, "")
	manualDevices := false
	if err := syscall.Mount("devtmpfs", "/dev", "devtmpfs", 0, "mode=0755"); err != nil {
		manualDevices = true
		_ = syscall.Mount("tmpfs", "/dev", "tmpfs", 0, "mode=0755")
		populateDevices()
	}
	attachConsole()
	parameters := readParameters()
	loadModules("/modules")
	root := parameters["root"]
	if root == "" {
		root = "/dev/vda"
	}
	if !waitFor(root, 30*time.Second, manualDevices) {
		halt("root device " + root + " did not appear")
	}
	if err := syscall.Mount(root, "/newroot", "squashfs", syscall.MS_RDONLY, ""); err != nil {
		halt("unable to mount the firmware root filesystem: " + err.Error())
	}
	_ = os.RemoveAll("/modules")
	_ = os.Remove("/init")
	mustMount("tmpfs", "/newroot/tmp", "tmpfs", 0, "mode=1777")
	mustMount("/dev", "/newroot/dev", "", syscall.MS_MOVE, "")
	mustMount("proc", "/newroot/proc", "proc", 0, "")
	mustMount("sysfs", "/newroot/sys", "sysfs", 0, "")
	_ = syscall.Unmount("/proc", syscall.MNT_DETACH)
	_ = syscall.Unmount("/sys", syscall.MNT_DETACH)
	if err := syscall.Chdir("/newroot"); err != nil {
		halt("chdir: " + err.Error())
	}
	if err := syscall.Mount(".", "/", "", syscall.MS_MOVE, ""); err != nil {
		halt("unable to move the root: " + err.Error())
	}
	if err := syscall.Chroot("."); err != nil {
		halt("chroot: " + err.Error())
	}
	_ = syscall.Chdir("/")
	_ = os.MkdirAll("/dev/pts", 0o755)
	mustMount("devpts", "/dev/pts", "devpts", 0, "mode=620,ptmxmode=666")
	attachConsole()
	return parameters, manualDevices
}

func seedRuntimeFiles() {
	files := map[string]string{
		"/tmp/passwd":      "root:x:0:0:root:/tmp:/bin/sh\nnobody:x:65534:65534:nobody:/tmp:/bin/false\n",
		"/tmp/group":       "root:x:0:\nnobody:x:65534:\n",
		"/tmp/hosts":       "127.0.0.1 localhost\n",
		"/tmp/resolv.conf": "",
		"/tmp/TZ":          "UTC0\n",
	}
	for name, content := range files {
		_ = os.WriteFile(name, []byte(content), 0o644)
	}
	_ = os.MkdirAll("/tmp/mnt", 0o755)
	_ = os.MkdirAll("/tmp/run", 0o755)
}

func listenSyslog() {
	_ = os.Remove("/dev/log")
	socket, err := net.ListenUnixgram("unixgram", &net.UnixAddr{Name: "/dev/log", Net: "unixgram"})
	if err != nil {
		emuLog(levelWarn, "syslog socket: %s", errorString(err))
		return
	}
	_ = os.Chmod("/dev/log", 0o666)
	buffer := make([]byte, 8192)
	for {
		count, _, err := socket.ReadFromUnix(buffer)
		if err != nil {
			return
		}
		text := strings.TrimRight(string(buffer[:count]), "\x00\r\n")
		if strings.HasPrefix(text, "<") {
			if end := strings.IndexByte(text, '>'); end > 0 && end < 5 {
				text = text[end+1:]
			}
		}
		if len(text) > 16 && text[3] == ' ' && text[6] == ' ' && text[9] == ':' && text[12] == ':' {
			text = text[16:]
		}
		tag, message, found := strings.Cut(text, ": ")
		if !found {
			tag, message = "syslog", text
		}
		logbook.write(levelInfo, tag, message)
	}
}

func prepareMemory(parameters map[string]string) {
	zram := int64(512 << 20)
	if text, given := parameters["zram"]; given {
		zram, _ = parseSize(text)
	}
	if zram > 0 {
		populateDevices()
		if err := setupZram(zram); err != nil {
			emuLog(levelWarn, "zram swap is not set up: %s", errorString(err))
		} else {
			emuLog(levelInfo, "zram swap of %d kB enabled", zram>>10)
		}
	}
	target := int64(254280)
	if text, given := parameters["memfree"]; given {
		target, _ = strconv.ParseInt(text, 10, 64)
	}
	size := int64(0)
	switch text := parameters["ballast"]; text {
	case "", "auto":
		size = (readMeminfo()["MemFree"] - target) << 10
	default:
		size, _ = parseSize(text)
	}
	if size > 0 {
		if err := holdBallast(size &^ 4095); err != nil {
			emuLog(levelWarn, "ballast of %d kB: %s", size>>10, errorString(err))
		}
	}
	memory := readMeminfo()
	emuLog(levelInfo, "memory: MemTotal %d kB, MemFree %d kB, MemAvailable %d kB, SwapTotal %d kB, ballast %d kB locked", memory["MemTotal"], memory["MemFree"], memory["MemAvailable"], memory["SwapTotal"], int64(len(ballast))>>10)
}

func main() {
	if os.Getpid() != 1 {
		fmt.Println("ndm: this program is the init of the Keenetic emulator and only runs as PID 1")
		os.Exit(2)
	}
	defer func() {
		if failure := recover(); failure != nil {
			halt(fmt.Sprint("panic: ", failure))
		}
	}()
	parameters, manualDevices := bootstrap()
	logbook.out = os.Stdout
	go reapChildren()
	if directory := parameters["cwd"]; directory != "" {
		_ = syscall.Chdir(directory)
	}
	var release syscall.Utsname
	_ = syscall.Uname(&release)
	version := make([]byte, 0, 65)
	for _, char := range release.Release {
		if char == 0 {
			break
		}
		version = append(version, byte(char))
	}
	emuLog(levelInfo, "fake NDM started on Linux %s, uptime %s s", version, uptime())
	seedRuntimeFiles()
	go listenSyslog()
	setupNetwork(parameters["net"])
	prepareMemory(parameters)
	wait := 20 * time.Second
	if text, given := parameters["diskwait"]; given {
		if seconds, err := strconv.Atoi(text); err == nil {
			wait = time.Duration(seconds) * time.Second
		}
	}
	service := &daemon{
		opkg:  &opkg{manualDevices: manualDevices, diskWait: wait, unpacker: parameters["npkg"]},
		tasks: make(chan func(), 16),
	}
	go service.work()
	if manualDevices {
		populateDevices()
	}
	if port, err := os.OpenFile("/dev/ttyAMA1", os.O_RDWR|syscall.O_NOCTTY, 0); err == nil {
		setRaw(port)
		go service.serve(port, port)
	} else {
		emuLog(levelWarn, "control port /dev/ttyAMA1: %s", errorString(err))
	}
	go service.serve(os.Stdin, os.Stdout)
	if parameters["auto"] == "1" {
		service.queued(func() {
			if parameters["chroot"] != "0" {
				service.opkg.setChroot(true)
			}
			disk := parameters["disk"]
			if disk == "" {
				disk = "NIX"
			}
			service.opkg.setDisk(disk+":/", parameters["url"])
		})
		if parameters["once"] == "1" {
			service.queued(service.shutdown)
		}
	}
	select {}
}
