package main

import (
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

type socketAddress struct {
	family  uint16
	port    uint16
	address [4]byte
	zero    [8]byte
}

type interfaceRequest struct {
	name    [16]byte
	address socketAddress
	padding [8]byte
}

type flagsRequest struct {
	name    [16]byte
	flags   uint16
	padding [22]byte
}

type routeEntry struct {
	pad1    uint64
	target  socketAddress
	gateway socketAddress
	mask    socketAddress
	flags   uint16
	pad2    int16
	pad3    uint64
	pad4    uintptr
	metric  int16
	device  uintptr
	mtu     uint64
	window  uint64
	irtt    uint16
}

func control(fd int, request uintptr, argument unsafe.Pointer) error {
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), request, uintptr(argument)); errno != 0 {
		return errno
	}
	return nil
}

func inet(address net.IP) socketAddress {
	result := socketAddress{family: syscall.AF_INET}
	copy(result.address[:], address.To4())
	return result
}

func linkUp(fd int, name string) error {
	request := flagsRequest{}
	copy(request.name[:], name)
	if err := control(fd, syscall.SIOCGIFFLAGS, unsafe.Pointer(&request)); err != nil {
		return err
	}
	request.flags |= syscall.IFF_UP | syscall.IFF_RUNNING
	return control(fd, syscall.SIOCSIFFLAGS, unsafe.Pointer(&request))
}

func assignAddress(fd int, name string, address net.IP, mask net.IPMask, gateway net.IP) error {
	request := interfaceRequest{address: inet(address)}
	copy(request.name[:], name)
	if err := control(fd, syscall.SIOCSIFADDR, unsafe.Pointer(&request)); err != nil {
		return err
	}
	request.address = inet(net.IP(mask))
	if err := control(fd, syscall.SIOCSIFNETMASK, unsafe.Pointer(&request)); err != nil {
		return err
	}
	if gateway == nil {
		return nil
	}
	route := routeEntry{
		target:  inet(net.IPv4zero),
		gateway: inet(gateway),
		mask:    inet(net.IPv4zero),
		flags:   syscall.RTF_UP | syscall.RTF_GATEWAY,
	}
	return control(fd, syscall.SIOCADDRT, unsafe.Pointer(&route))
}

func firstInterface() string {
	entries, err := os.ReadDir("/sys/class/net")
	if err != nil {
		return ""
	}
	for _, entry := range entries {
		if entry.Name() != "lo" {
			return entry.Name()
		}
	}
	return ""
}

type lease struct {
	address net.IP
	mask    net.IPMask
	gateway net.IP
	servers []net.IP
}

func dhcpMessage(kind byte, transaction uint32, hardware net.HardwareAddr, requested, server net.IP) []byte {
	packet := make([]byte, 240, 320)
	packet[0], packet[1], packet[2] = 1, 1, 6
	binary.BigEndian.PutUint32(packet[4:], transaction)
	binary.BigEndian.PutUint16(packet[10:], 0x8000)
	copy(packet[28:], hardware)
	copy(packet[236:], []byte{99, 130, 83, 99})
	packet = append(packet, 53, 1, kind)
	if requested != nil {
		packet = append(append(packet, 50, 4), requested.To4()...)
	}
	if server != nil {
		packet = append(append(packet, 54, 4), server.To4()...)
	}
	packet = append(packet, 55, 3, 1, 3, 6, 255)
	return packet
}

func dhcpExchange(fd int, message []byte, transaction uint32, expected byte) (lease, net.IP, error) {
	broadcast := &syscall.SockaddrInet4{Port: 67, Addr: [4]byte{255, 255, 255, 255}}
	buffer := make([]byte, 1500)
	for attempt := 0; attempt < 4; attempt++ {
		if err := syscall.Sendto(fd, message, 0, broadcast); err != nil {
			return lease{}, nil, err
		}
		deadline := time.Now().Add(2 * time.Second)
		for time.Now().Before(deadline) {
			count, _, err := syscall.Recvfrom(fd, buffer, 0)
			if err != nil {
				break
			}
			if count < 240 || buffer[0] != 2 || binary.BigEndian.Uint32(buffer[4:]) != transaction {
				continue
			}
			result := lease{address: net.IP(append([]byte{}, buffer[16:20]...))}
			var server net.IP
			kind := byte(0)
			options := buffer[240:count]
			for len(options) >= 2 && options[0] != 255 {
				if options[0] == 0 {
					options = options[1:]
					continue
				}
				size := int(options[1])
				if len(options) < 2+size {
					break
				}
				value := append([]byte{}, options[2:2+size]...)
				switch options[0] {
				case 1:
					result.mask = net.IPMask(value)
				case 3:
					if size >= 4 {
						result.gateway = net.IP(value[:4])
					}
				case 6:
					for offset := 0; offset+4 <= size; offset += 4 {
						result.servers = append(result.servers, net.IP(value[offset:offset+4]))
					}
				case 53:
					kind = value[0]
				case 54:
					server = net.IP(value)
				}
				options = options[2+size:]
			}
			if kind == expected {
				return result, server, nil
			}
		}
	}
	return lease{}, nil, fmt.Errorf("no DHCP answer")
}

func requestLease(name string) (lease, error) {
	device, err := net.InterfaceByName(name)
	if err != nil {
		return lease{}, err
	}
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_DGRAM, 0)
	if err != nil {
		return lease{}, err
	}
	defer func() { _ = syscall.Close(fd) }()
	_ = syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_REUSEADDR, 1)
	_ = syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_BROADCAST, 1)
	if err := syscall.BindToDevice(fd, name); err != nil {
		return lease{}, err
	}
	_ = syscall.SetsockoptTimeval(fd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &syscall.Timeval{Sec: 1})
	if err := syscall.Bind(fd, &syscall.SockaddrInet4{Port: 68}); err != nil {
		return lease{}, err
	}
	token := make([]byte, 4)
	_, _ = rand.Read(token)
	transaction := binary.BigEndian.Uint32(token)
	offer, server, err := dhcpExchange(fd, dhcpMessage(1, transaction, device.HardwareAddr, nil, nil), transaction, 2)
	if err != nil {
		return lease{}, err
	}
	granted, _, err := dhcpExchange(fd, dhcpMessage(3, transaction, device.HardwareAddr, offer.address, server), transaction, 5)
	return granted, err
}

func setupNetwork(mode string) {
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_DGRAM, 0)
	if err != nil {
		emuLog(levelError, "network: %s", errorString(err))
		return
	}
	defer func() { _ = syscall.Close(fd) }()
	_ = linkUp(fd, "lo")
	name := firstInterface()
	if name == "" {
		emuLog(levelWarn, "network: no interface")
		return
	}
	if err := linkUp(fd, name); err != nil {
		emuLog(levelError, "network: unable to bring %s up: %s", name, errorString(err))
		return
	}
	settings := lease{
		address: net.IPv4(10, 0, 2, 15),
		mask:    net.CIDRMask(24, 32),
		gateway: net.IPv4(10, 0, 2, 2),
		servers: []net.IP{net.IPv4(10, 0, 2, 3)},
	}
	switch {
	case mode == "none":
		return
	case mode == "dhcp":
		granted, err := requestLease(name)
		if err != nil {
			emuLog(levelError, "network: DHCP on %s failed: %s", name, errorString(err))
			return
		}
		settings = granted
		if settings.mask == nil {
			settings.mask = net.CIDRMask(24, 32)
		}
	case mode != "" && mode != "static":
		fields := strings.Split(mode, ",")
		address, network, err := net.ParseCIDR(fields[0])
		if err != nil {
			emuLog(levelError, "network: bad address %q", mode)
			return
		}
		settings = lease{address: address, mask: network.Mask}
		if len(fields) > 1 {
			settings.gateway = net.ParseIP(fields[1])
		}
		if len(fields) > 2 {
			settings.servers = []net.IP{net.ParseIP(fields[2])}
		}
	}
	if err := assignAddress(fd, name, settings.address, settings.mask, settings.gateway); err != nil {
		emuLog(levelError, "network: unable to configure %s: %s", name, errorString(err))
		return
	}
	resolver := ""
	for _, server := range settings.servers {
		if server != nil {
			resolver += "nameserver " + server.String() + "\n"
		}
	}
	_ = os.WriteFile("/tmp/resolv.conf", []byte(resolver), 0o644)
	prefix, _ := settings.mask.Size()
	emuLog(levelInfo, "network: %s %s/%d gateway %v (%s)", name, settings.address, prefix, settings.gateway, map[bool]string{true: "dhcp", false: "static"}[mode == "dhcp"])
}
