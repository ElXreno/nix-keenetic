package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"syscall"
	"time"
)

type daemon struct {
	opkg  *opkg
	tasks chan func()
}

func (d *daemon) work() {
	for task := range d.tasks {
		task()
	}
}

func (d *daemon) queued(task func()) {
	done := make(chan struct{})
	d.tasks <- func() {
		task()
		close(done)
	}
	<-done
}

func exitStatus(status int) int {
	if status == statusIdle || status == statusStarted {
		return 0
	}
	return 10 + status
}

func (d *daemon) shutdown() {
	d.opkg.release()
	syscall.Sync()
	logbook.write(levelInfo, "ndm", fmt.Sprintf("Emulator: exit status %d (%s).", exitStatus(d.opkg.status), statusNames[d.opkg.status]))
	time.Sleep(200 * time.Millisecond)
	_ = syscall.Reboot(syscall.LINUX_REBOOT_CMD_POWER_OFF)
	select {}
}

func lookPath(name string) string {
	if strings.Contains(name, "/") {
		return name
	}
	for _, directory := range strings.Split(ndmSearchPath, ":") {
		candidate := directory + "/" + name
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate
		}
	}
	return name
}

func (d *daemon) command(line string, reply func(string)) string {
	words := strings.Fields(line)
	if len(words) == 0 {
		return ""
	}
	negated := words[0] == "no"
	if negated {
		words = words[1:]
	}
	joined := strings.Join(words, " ")
	switch {
	case strings.HasPrefix(joined, "opkg disk") && negated:
		d.queued(func() {
			if d.opkg.mounted {
				d.opkg.unmount()
			}
			d.opkg.disk = ""
			d.opkg.status = statusIdle
		})
		return "ok"
	case strings.HasPrefix(joined, "opkg disk") && len(words) >= 3:
		link := ""
		if len(words) > 3 {
			link = words[3]
		}
		d.queued(func() { d.opkg.setDisk(words[2], link) })
		reply(statusNames[d.opkg.status])
		if exitStatus(d.opkg.status) != 0 {
			return "error: " + statusNames[d.opkg.status]
		}
		return "ok"
	case joined == "opkg chroot":
		d.queued(func() { d.opkg.setChroot(!negated) })
		return "ok"
	case strings.HasPrefix(joined, "opkg initrc"):
		d.queued(func() {
			d.opkg.initrc = ""
			if !negated && len(words) > 2 {
				d.opkg.initrc = words[2]
			}
		})
		return "ok"
	case words[0] == "hook" && len(words) >= 2:
		var outcome scriptOutcome
		var mounted bool
		d.queued(func() { outcome, mounted = d.opkg.hook(words[1], words[2:]) })
		if !mounted {
			return "error: opkg disk is not mounted"
		}
		reply(fmt.Sprintf("scripts %d, succeeded %d, failed %d, timed out %d, not started %d", outcome.total, outcome.succeeded, outcome.failed, outcome.timedOut, outcome.notStarted))
		return "ok"
	case joined == "show log":
		for _, entry := range logbook.snapshot() {
			reply(entry)
		}
		return "ok"
	case joined == "show status":
		reply(fmt.Sprintf("status %d (%s), disk %q, chroot %v, mounted %v", exitStatus(d.opkg.status), statusNames[d.opkg.status], d.opkg.disk, d.opkg.chroot, d.opkg.mounted))
		return "ok"
	case joined == "show meminfo":
		return showFile("/proc/meminfo", reply)
	case joined == "show mounts":
		return showFile("/proc/mounts", reply)
	case words[0] == "cat" && len(words) == 2:
		return showFile(words[1], reply)
	case words[0] == "ls" && len(words) == 2:
		entries, err := os.ReadDir(words[1])
		if err != nil {
			return "error: " + errorString(err)
		}
		var names []string
		for _, entry := range entries {
			names = append(names, entry.Name())
		}
		sort.Strings(names)
		for _, name := range names {
			reply(name)
		}
		return "ok"
	case (words[0] == "exec" || words[0] == "opt-exec") && len(words) >= 2:
		root, environment := "", []string{"PATH=" + ndmSearchPath}
		program, arguments := lookPath(words[1]), words[2:]
		if words[0] == "opt-exec" {
			root, environment = optDirectory, []string{"PATH=" + scriptPath, "HOME=/root"}
			program, arguments = "/bin/sh", []string{"-c", strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "opt-exec"))}
		}
		result := launch("exec", program, arguments, environment, root, 10*time.Minute, reply)
		switch {
		case !result.started:
			return "error: not started"
		case result.timedOut:
			return "error: timed out"
		case result.exitCode != 0:
			return fmt.Sprintf("error: exit code %d", result.exitCode)
		}
		return "ok"
	case joined == "poweroff":
		go func() {
			time.Sleep(100 * time.Millisecond)
			d.queued(d.shutdown)
		}()
		return "ok"
	case joined == "help":
		for _, text := range []string{
			"opkg disk <label>:/ [url] | no opkg disk",
			"opkg chroot | no opkg chroot",
			"opkg initrc <path> | no opkg initrc",
			"hook <dir> [KEY=VALUE...]",
			"show log | show status | show meminfo | show mounts",
			"cat <file> | ls <dir>",
			"exec <program> [args...] | opt-exec <shell command line run by /bin/sh inside /opt>",
			"poweroff",
		} {
			reply(text)
		}
		return "ok"
	}
	return "error: unknown command"
}

func showFile(name string, reply func(string)) string {
	data, err := os.ReadFile(name)
	if err != nil {
		return "error: " + errorString(err)
	}
	for _, text := range strings.Split(strings.TrimRight(string(data), "\n"), "\n") {
		reply(text)
	}
	return "ok"
}

func (d *daemon) serve(input io.Reader, output io.Writer) {
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 0x10000), 0x100000)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		result := d.command(line, func(text string) {
			_, _ = io.WriteString(output, text+"\r\n")
		})
		_, _ = io.WriteString(output, "= "+result+"\r\n")
	}
}
