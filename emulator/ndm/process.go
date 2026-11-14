package main

import (
	"bufio"
	"os"
	"os/signal"
	"path"
	"strings"
	"sync"
	"syscall"
	"time"
)

const ndmSearchPath = "/bin:/sbin:/usr/bin:/usr/sbin"

var (
	childrenLock sync.Mutex
	children     = map[int]chan syscall.WaitStatus{}
)

func reapChildren() {
	signals := make(chan os.Signal, 64)
	signal.Notify(signals, syscall.SIGCHLD)
	ticker := time.NewTicker(time.Second)
	for {
		for {
			var status syscall.WaitStatus
			childrenLock.Lock()
			pid, err := syscall.Wait4(-1, &status, syscall.WNOHANG, nil)
			if pid > 0 {
				if waiter, known := children[pid]; known {
					waiter <- status
					delete(children, pid)
				}
			}
			childrenLock.Unlock()
			if pid <= 0 || err != nil {
				break
			}
		}
		select {
		case <-signals:
		case <-ticker.C:
		}
	}
}

func canonical(name string) string {
	if !strings.HasPrefix(name, "/") {
		directory, err := os.Getwd()
		if err != nil {
			directory = "/"
		}
		name = directory + "/" + name
	}
	return path.Clean(name)
}

type lookupFailure struct {
	level rune
	code  uint32
	text  string
}

func findExecutable(name, root string) (string, *lookupFailure) {
	rootPrefix := ""
	if root != "" {
		rootPrefix = canonical(root)
		if !strings.HasSuffix(rootPrefix, "/") {
			rootPrefix += "/"
		}
	}
	if strings.TrimSpace(name) == "" {
		return "", &lookupFailure{levelError, 0xcffd0ab3, ""}
	}
	directories := []string{""}
	if !strings.HasPrefix(name, "/") {
		directories = append([]string{"."}, strings.Split(ndmSearchPath, ":")...)
	}
	for _, directory := range directories {
		candidate := rootPrefix + directory + "/" + name
		original := ""
		if rootPrefix != "" {
			budget := 8
			for {
				if original == "" {
					original = candidate
				}
				if !isSymlink(candidate) {
					break
				}
				budget--
				if budget == 0 {
					return "", &lookupFailure{levelWarn, 0x80081450, nfmt(`too many levels of symbolic links for "%1"`, name)}
				}
				target, err := os.Readlink(candidate)
				if err != nil {
					return "", &lookupFailure{levelWarn, 0x800814b4, nfmt(`unable to read symlink "%1": "%2"`, candidate, errorString(err))}
				}
				candidate = rootPrefix + canonical(target)
			}
		}
		var info syscall.Stat_t
		if err := syscall.Stat(candidate, &info); err != nil {
			if err == syscall.ENOENT {
				continue
			}
			if err != syscall.EOVERFLOW {
				return "", &lookupFailure{levelError, 0xcffd0b23, ""}
			}
		}
		regular := info.Mode&syscall.S_IFMT == syscall.S_IFREG
		if !regular || syscall.Access(candidate, 4) != nil || syscall.Access(candidate, 1) != nil {
			return "", &lookupFailure{levelWarn, 0x80081518, nfmt(`"%1" is not an executable`, name)}
		}
		if original != "" {
			return canonical(original), nil
		}
		return canonical(candidate), nil
	}
	return "", &lookupFailure{levelWarn, 0x80081388, nfmt(`"%1" executable not found`, name)}
}

type processResult struct {
	created  bool
	started  bool
	exitCode int
	timedOut bool
}

func runProcess(title, executable string, arguments, environment []string, root string, limit time.Duration, line func(string)) processResult {
	resolved, failure := findExecutable(executable, root)
	if failure != nil {
		if failure.code&0xffff0000 == 0xcffd0000 {
			ndmFail("Process", failure.code, "%1", failure.text)
		} else {
			ndmLog(failure.level, "Process", "%1", failure.text)
		}
		ndmLog(levelWarn, "Process", `unable to create and initialize "%1" process`, title)
		ndmLog(levelWarn, "Io::Process", `"%1" is broken`, title)
		return processResult{}
	}
	return launch(title, resolved, arguments, environment, root, limit, line)
}

func launch(title, resolved string, arguments, environment []string, root string, limit time.Duration, line func(string)) processResult {
	reader, writer, err := os.Pipe()
	if err != nil {
		ndmFail("Process", 0xcffd0001, `"%1": unable to create I/O descriptors`, title)
		return processResult{created: true}
	}
	null, err := os.Open("/dev/null")
	if err != nil {
		_ = reader.Close()
		_ = writer.Close()
		ndmLog(levelError, "Process", `"%1": unable to open the null device`, title)
		return processResult{created: true}
	}
	attributes := &syscall.ProcAttr{
		Dir:   "/",
		Env:   environment,
		Files: []uintptr{null.Fd(), writer.Fd(), writer.Fd()},
		Sys:   &syscall.SysProcAttr{Setsid: true, Chroot: root},
	}
	childrenLock.Lock()
	pid, err := syscall.ForkExec(resolved, append([]string{resolved}, arguments...), attributes)
	done := make(chan syscall.WaitStatus, 1)
	if err == nil {
		children[pid] = done
	}
	childrenLock.Unlock()
	_ = writer.Close()
	_ = null.Close()
	if err != nil {
		_ = reader.Close()
		ndmLog(levelError, "Process", `"%1": unable to start (unable to execute a process: %2)`, title, errorString(err))
		return processResult{created: true}
	}
	lines := make(chan string, 64)
	go func() {
		scanner := bufio.NewScanner(reader)
		scanner.Buffer(make([]byte, 0x1000), 0x100000)
		for scanner.Scan() {
			lines <- scanner.Text()
		}
		close(lines)
	}()
	readDeadline := time.After(limit)
reading:
	for {
		select {
		case text, open := <-lines:
			if !open {
				break reading
			}
			if line != nil {
				line(text)
			}
		case <-readDeadline:
			break reading
		}
	}
	go func() {
		for range lines {
		}
		_ = reader.Close()
	}()
	select {
	case status := <-done:
		return processResult{created: true, started: true, exitCode: exitCode(status)}
	case <-time.After(limit):
	}
	_ = syscall.Kill(pid, syscall.SIGTERM)
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		_ = syscall.Kill(pid, syscall.SIGKILL)
	}
	return processResult{created: true, started: true, timedOut: true}
}

func exitCode(status syscall.WaitStatus) int {
	if status.Signaled() {
		return 128 + int(status.Signal())
	}
	return status.ExitStatus()
}

func printable(text string) bool {
	if strings.TrimSpace(text) == "" {
		return false
	}
	for index := 0; index < len(text); index++ {
		if text[index] < 0x20 || text[index] > 0x7e {
			return false
		}
	}
	return true
}
