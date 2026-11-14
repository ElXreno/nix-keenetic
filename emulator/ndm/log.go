package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	levelInfo  = 'I'
	levelWarn  = 'W'
	levelError = 'E'
	levelCrit  = 'C'
)

type journal struct {
	mu    sync.Mutex
	lines []string
	out   *os.File
}

var logbook = &journal{}

func (j *journal) write(level rune, tag, text string) {
	line := fmt.Sprintf("[%c] %s %s: %s", level, time.Now().Format("Jan _2 15:04:05"), tag, text)
	j.mu.Lock()
	j.lines = append(j.lines, line)
	if len(j.lines) > 4096 {
		j.lines = j.lines[len(j.lines)-4096:]
	}
	out := j.out
	j.mu.Unlock()
	if out != nil {
		_, _ = out.WriteString(line + "\r\n")
	}
}

func (j *journal) snapshot() []string {
	j.mu.Lock()
	defer j.mu.Unlock()
	return append([]string(nil), j.lines...)
}

func nfmt(format string, args ...any) string {
	text := format
	for index, arg := range args {
		text = strings.ReplaceAll(text, "%"+strconv.Itoa(index+1), fmt.Sprint(arg))
	}
	return text
}

func sentence(text string) string {
	if text == "" || strings.HasSuffix(text, ".") {
		return text
	}
	return text + "."
}

func ndmLog(level rune, source, format string, args ...any) {
	logbook.write(level, "ndm", source+": "+sentence(nfmt(format, args...)))
}

func ndmFail(source string, code uint32, format string, args ...any) {
	text := nfmt(format, args...)
	if text == "" {
		logbook.write(levelError, "ndm", fmt.Sprintf("%s: system failed [0x%08x].", source, code))
		return
	}
	logbook.write(levelError, "ndm", fmt.Sprintf("%s: system failed [0x%08x], %s", source, code, sentence(text)))
}

func emuLog(level rune, format string, args ...any) {
	logbook.write(level, "ndm", "Emulator: "+sentence(fmt.Sprintf(format, args...)))
}

func errorString(err error) string {
	if err == nil {
		return "success"
	}
	for {
		switch typed := err.(type) {
		case *os.PathError:
			err = typed.Err
			continue
		case *os.LinkError:
			err = typed.Err
			continue
		case *os.SyscallError:
			err = typed.Err
			continue
		case syscall.Errno:
			return strings.ToLower(typed.Error())
		}
		return strings.ToLower(err.Error())
	}
}
