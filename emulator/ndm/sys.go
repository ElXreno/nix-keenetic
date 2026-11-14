package main

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

func access(path string) bool {
	return syscall.Access(path, 0) == nil
}

func isDirectory(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func isSymlink(path string) bool {
	info, err := os.Lstat(path)
	return err == nil && info.Mode()&os.ModeSymlink != 0
}

func readParameters() map[string]string {
	parameters := map[string]string{}
	data, err := os.ReadFile("/proc/cmdline")
	if err != nil {
		return parameters
	}
	for _, word := range strings.Fields(string(data)) {
		if !strings.HasPrefix(word, "ndm.") {
			continue
		}
		key, value, _ := strings.Cut(strings.TrimPrefix(word, "ndm."), "=")
		parameters[key] = value
	}
	return parameters
}

func makeDevice(major, minor uint64) int {
	return int((major&0xfff)<<8 | minor&0xff | (minor&^0xff)<<12)
}

func populateDevices() {
	for kind, mode := range map[string]uint32{"block": syscall.S_IFBLK, "char": syscall.S_IFCHR} {
		entries, err := os.ReadDir("/sys/dev/" + kind)
		if err != nil {
			continue
		}
		for _, entry := range entries {
			majorText, minorText, found := strings.Cut(entry.Name(), ":")
			if !found {
				continue
			}
			major, _ := strconv.ParseUint(majorText, 10, 32)
			minor, _ := strconv.ParseUint(minorText, 10, 32)
			uevent, err := os.ReadFile("/sys/dev/" + kind + "/" + entry.Name() + "/uevent")
			if err != nil {
				continue
			}
			name := ""
			for _, line := range strings.Split(string(uevent), "\n") {
				if value, ok := strings.CutPrefix(line, "DEVNAME="); ok {
					name = value
				}
			}
			if name == "" {
				continue
			}
			path := "/dev/" + name
			if _, err := os.Lstat(path); err == nil {
				continue
			}
			_ = os.MkdirAll(filepath.Dir(path), 0o755)
			_ = syscall.Mknod(path, mode|0o600, makeDevice(major, minor))
		}
	}
}

func loadModules(directory string) {
	order, err := os.ReadFile(directory + "/order")
	if err != nil {
		return
	}
	empty := []byte{0}
	for _, name := range strings.Fields(string(order)) {
		image, err := os.ReadFile(directory + "/" + name)
		if err != nil || len(image) == 0 {
			continue
		}
		_, _, errno := syscall.Syscall(syscall.SYS_INIT_MODULE, uintptr(unsafe.Pointer(&image[0])), uintptr(len(image)), uintptr(unsafe.Pointer(&empty[0])))
		if errno != 0 && errno != syscall.EEXIST {
			fmt.Printf("ndm: module %s: %s\r\n", name, errno)
		}
	}
}

func waitFor(path string, limit time.Duration, manualDevices bool) bool {
	deadline := time.Now().Add(limit)
	for {
		if manualDevices {
			populateDevices()
		}
		if access(path) {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(100 * time.Millisecond)
	}
}

type partition struct {
	device string
	label  string
	uuid   string
}

func readExtIdentity(device string) (partition, bool) {
	file, err := os.Open(device)
	if err != nil {
		return partition{}, false
	}
	defer func() { _ = file.Close() }()
	block := make([]byte, 1024)
	if _, err := file.ReadAt(block, 1024); err != nil {
		return partition{}, false
	}
	if binary.LittleEndian.Uint16(block[56:]) != 0xef53 {
		return partition{}, false
	}
	raw := block[104:120]
	uuid := fmt.Sprintf("%x-%x-%x-%x-%x", raw[0:4], raw[4:6], raw[6:8], raw[8:10], raw[10:16])
	label := strings.TrimRight(string(block[120:136]), "\x00")
	return partition{device: device, label: label, uuid: uuid}, true
}

func findPartition(name string, manualDevices bool) (partition, bool) {
	if manualDevices {
		populateDevices()
	}
	entries, err := os.ReadDir("/sys/class/block")
	if err != nil {
		return partition{}, false
	}
	for _, entry := range entries {
		if !access("/sys/class/block/" + entry.Name() + "/partition") {
			continue
		}
		found, ok := readExtIdentity("/dev/" + entry.Name())
		if ok && (found.label == name || found.uuid == name) {
			return found, true
		}
	}
	return partition{}, false
}

type mountEntry struct {
	source  string
	target  string
	fstype  string
	options string
}

func readMounts() ([]mountEntry, error) {
	file, err := os.Open("/proc/mounts")
	if err != nil {
		return nil, err
	}
	defer func() { _ = file.Close() }()
	var entries []mountEntry
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		fields := strings.Split(strings.TrimSpace(scanner.Text()), " ")
		if len(fields) != 6 {
			continue
		}
		entries = append(entries, mountEntry{fields[0], fields[1], fields[2], fields[3]})
	}
	return entries, nil
}

func readMeminfo() map[string]int64 {
	values := map[string]int64{}
	data, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return values
	}
	for _, line := range strings.Split(string(data), "\n") {
		key, rest, found := strings.Cut(line, ":")
		if !found {
			continue
		}
		fields := strings.Fields(rest)
		if len(fields) == 0 {
			continue
		}
		value, _ := strconv.ParseInt(fields[0], 10, 64)
		values[key] = value
	}
	return values
}

func parseSize(text string) (int64, bool) {
	if text == "" {
		return 0, false
	}
	multiplier := int64(1)
	switch text[len(text)-1] {
	case 'k', 'K':
		multiplier = 1 << 10
		text = text[:len(text)-1]
	case 'm', 'M':
		multiplier = 1 << 20
		text = text[:len(text)-1]
	case 'g', 'G':
		multiplier = 1 << 30
		text = text[:len(text)-1]
	}
	value, err := strconv.ParseInt(text, 10, 64)
	if err != nil {
		return 0, false
	}
	return value * multiplier, true
}

var ballast []byte

func holdBallast(size int64) error {
	if size <= 0 {
		return nil
	}
	region, err := syscall.Mmap(-1, 0, int(size), syscall.PROT_READ|syscall.PROT_WRITE, syscall.MAP_ANON|syscall.MAP_PRIVATE)
	if err != nil {
		return err
	}
	for offset := 0; offset < len(region); offset += 4096 {
		region[offset] = 0xa5
	}
	ballast = region
	return syscall.Mlock(region)
}

func setupZram(size int64) error {
	if !access("/sys/block/zram0") {
		return fmt.Errorf("no zram device")
	}
	if err := os.WriteFile("/sys/block/zram0/disksize", []byte(strconv.FormatInt(size, 10)), 0o200); err != nil {
		return err
	}
	device, err := os.OpenFile("/dev/zram0", os.O_WRONLY, 0)
	if err != nil {
		return err
	}
	header := make([]byte, 4096)
	binary.LittleEndian.PutUint32(header[1024:], 1)
	binary.LittleEndian.PutUint32(header[1028:], uint32(size/4096-1))
	copy(header[4086:], "SWAPSPACE2")
	_, err = device.WriteAt(header, 0)
	_ = device.Close()
	if err != nil {
		return err
	}
	path := []byte("/dev/zram0\x00")
	_, _, errno := syscall.Syscall(syscall.SYS_SWAPON, uintptr(unsafe.Pointer(&path[0])), 0, 0)
	if errno != 0 {
		return errno
	}
	return nil
}

func setRaw(file *os.File) {
	var state syscall.Termios
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, file.Fd(), syscall.TCGETS, uintptr(unsafe.Pointer(&state))); errno != 0 {
		return
	}
	state.Iflag &^= syscall.IGNBRK | syscall.BRKINT | syscall.PARMRK | syscall.ISTRIP | syscall.INLCR | syscall.IGNCR | syscall.ICRNL | syscall.IXON
	state.Oflag &^= syscall.OPOST
	state.Lflag &^= syscall.ECHO | syscall.ECHONL | syscall.ICANON | syscall.ISIG | syscall.IEXTEN
	state.Cflag &^= syscall.CSIZE | syscall.PARENB
	state.Cflag |= syscall.CS8
	state.Cc[syscall.VMIN] = 1
	state.Cc[syscall.VTIME] = 0
	_, _, _ = syscall.Syscall(syscall.SYS_IOCTL, file.Fd(), syscall.TCSETS, uintptr(unsafe.Pointer(&state)))
}
