package main

import (
	"bufio"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

var (
	netfilterCall = regexp.MustCompile(`\$\(call nf_add,\s*([A-Z0-9_]+),\s*([A-Za-z0-9_=]+)\s*,([^)]*)\)`)
	defineBlock   = regexp.MustCompile(`^define KernelPackage/(\S+)\s*$`)
	assignment    = regexp.MustCompile(`^\s*KCONFIG\s*(:=|\+=|=)\s*(.*)$`)
	reference     = regexp.MustCompile(`\$\((?:call )?KernelPackage/([^),]+)`)
	variable      = regexp.MustCompile(`^\$\((KCONFIG_[A-Z0-9_]+)\)$`)
	versionSuffix = regexp.MustCompile(`@(lt|le|gt|ge|eq|ne)(\d+(?:\.\d+)+)`)
	setLine       = regexp.MustCompile(`^(CONFIG_[A-Za-z0-9_.+-]+)=(.*)$`)
	unsetLine     = regexp.MustCompile(`^# (CONFIG_[A-Za-z0-9_.+-]+) is not set$`)
)

func versionNumber(text string) int {
	number := 0
	parts := append(strings.Split(text, "."), "0", "0", "0", "0")
	for index := 0; index < 4; index++ {
		value, _ := strconv.Atoi(parts[index])
		number = number<<8 | value
	}
	return number
}

func versionMatches(operator, wanted, actual string) bool {
	left, right := versionNumber(actual), versionNumber(wanted)
	switch operator {
	case "lt":
		return left < right
	case "le":
		return left <= right
	case "gt":
		return left > right
	case "ge":
		return left >= right
	case "eq":
		return left == right
	}
	return left != right
}

func readLines(name string) []string {
	file, err := os.Open(name)
	if err != nil {
		fmt.Fprintln(os.Stderr, "kconfig:", err)
		os.Exit(1)
	}
	defer func() { _ = file.Close() }()
	var lines []string
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 1<<20), 1<<24)
	for scanner.Scan() {
		lines = append(lines, scanner.Text())
	}
	return lines
}

func joinContinuations(lines []string) []string {
	var joined []string
	pending := ""
	for _, line := range lines {
		if strings.HasSuffix(line, "\\") {
			pending += strings.TrimSuffix(line, "\\") + " "
			continue
		}
		joined = append(joined, pending+line)
		pending = ""
	}
	if pending != "" {
		joined = append(joined, pending)
	}
	return joined
}

func netfilterVariables(name, version string) map[string][]string {
	variables := map[string][]string{}
	for _, line := range joinContinuations(readLines(name)) {
		if strings.Contains(line, "$(if $(NF_KMOD),,") {
			continue
		}
		match := netfilterCall.FindStringSubmatch(line)
		if match == nil {
			continue
		}
		arguments := strings.Split(match[3], ",")
		if len(arguments) > 1 {
			condition := strings.Fields(arguments[len(arguments)-1])
			if len(condition) == 2 && !versionMatches(condition[0], condition[1], version) {
				continue
			}
		}
		key := "KCONFIG_" + match[1]
		kept := variables[key][:0:0]
		for _, symbol := range variables[key] {
			if symbol != match[2] {
				kept = append(kept, symbol)
			}
		}
		variables[key] = append(kept, match[2])
	}
	return variables
}

type kernelPackage struct {
	name     string
	symbols  []string
	includes []string
}

func kernelPackages(root string, variables map[string][]string) []*kernelPackage {
	var files []string
	_ = filepath.WalkDir(root, func(name string, entry fs.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return nil
		}
		if strings.HasSuffix(name, ".mk") || entry.Name() == "Makefile" {
			files = append(files, name)
		}
		return nil
	})
	sort.Strings(files)
	var packages []*kernelPackage
	for _, name := range files {
		var current *kernelPackage
		for _, line := range joinContinuations(readLines(name)) {
			if match := defineBlock.FindStringSubmatch(line); match != nil {
				current = &kernelPackage{name: match[1]}
				packages = append(packages, current)
				continue
			}
			if current == nil {
				continue
			}
			if strings.HasPrefix(line, "endef") {
				current = nil
				continue
			}
			for _, match := range reference.FindAllStringSubmatch(line, -1) {
				current.includes = append(current.includes, match[1])
			}
			match := assignment.FindStringSubmatch(line)
			if match == nil {
				continue
			}
			if match[1] != "+=" {
				current.symbols = nil
			}
			for _, word := range strings.Fields(match[2]) {
				if expanded := variable.FindStringSubmatch(word); expanded != nil {
					current.symbols = append(current.symbols, variables[expanded[1]]...)
				} else if strings.HasPrefix(word, "CONFIG_") {
					current.symbols = append(current.symbols, word)
				}
			}
		}
	}
	byName := map[string]*kernelPackage{}
	for _, item := range packages {
		byName[item.name] = item
	}
	for _, item := range packages {
		if len(item.symbols) > 0 {
			continue
		}
		for _, include := range item.includes {
			if template, known := byName[include]; known && template != item {
				item.symbols = append(item.symbols, template.symbols...)
			}
		}
	}
	return packages
}

type settings struct {
	values map[string]string
	order  []string
}

func newSettings() *settings {
	return &settings{values: map[string]string{}}
}

func (s *settings) set(symbol, value string) {
	if _, known := s.values[symbol]; !known {
		s.order = append(s.order, symbol)
	}
	s.values[symbol] = value
}

func (s *settings) load(lines []string, rename func(string) (string, bool)) {
	for _, line := range lines {
		symbol, value := "", ""
		if match := setLine.FindStringSubmatch(line); match != nil {
			symbol, value = match[1], match[2]
		} else if match := unsetLine.FindStringSubmatch(line); match != nil {
			symbol, value = match[1], "n"
		} else {
			continue
		}
		if rename != nil {
			renamed, ok := rename(symbol)
			if !ok {
				continue
			}
			symbol = renamed
		}
		s.set(symbol, value)
	}
}

func main() {
	sdk := flag.String("sdk", "", "keenetic-sdk checkout")
	target := flag.String("target", "mt7981", "target directory under target/linux")
	board := flag.String("board", "KN-1012", "board directory under the target")
	version := flag.String("version", "4.9", "kernel patch version")
	fragment := flag.String("fragment", "", "configuration applied last")
	report := flag.String("report", "", "file receiving the package derived overrides")
	flag.Parse()
	if *sdk == "" {
		flag.Usage()
		os.Exit(64)
	}
	platform := filepath.Join(*sdk, "target/linux")
	selection := newSettings()
	boardLines := readLines(filepath.Join(platform, *target, *board, "ndwrt.config"))
	selection.load(boardLines, nil)

	result := newSettings()
	for _, name := range []string{
		filepath.Join(platform, "generic", "config-"+*version),
		filepath.Join(platform, *target, "config-"+*version),
		filepath.Join(platform, *target, *board, "config-"+*version),
	} {
		result.load(readLines(name), nil)
	}
	result.load(boardLines, func(symbol string) (string, bool) {
		renamed, ok := strings.CutPrefix(symbol, "CONFIG_KERNEL_")
		return "CONFIG_" + renamed, ok
	})
	result.set("CONFIG_KALLSYMS_EXTRA_PASS", "n")
	result.set("CONFIG_KALLSYMS_ALL", "n")
	result.set("CONFIG_KPROBES", "n")
	result.set("CONFIG_KALLSYMS_UNCOMPRESSED", "y")

	variables := netfilterVariables(filepath.Join(*sdk, "include/netfilter.mk"), *version)
	overrides := newSettings()
	for _, item := range kernelPackages(*sdk, variables) {
		chosen := selection.values["CONFIG_PACKAGE_kmod-"+item.name]
		selected := chosen == "y" || chosen == "m"
		for _, word := range item.symbols {
			if match := versionSuffix.FindStringSubmatch(word); match != nil {
				if !versionMatches(match[1], match[2], *version) {
					continue
				}
				word = versionSuffix.ReplaceAllString(word, "")
			}
			symbol, value, explicit := strings.Cut(word, "=")
			if !explicit {
				value = "m"
			}
			switch {
			case selected:
				if overrides.values[symbol] != "y" {
					overrides.set(symbol, value)
				}
			case !explicit:
				if _, known := overrides.values[symbol]; !known {
					overrides.set(symbol, "n")
				}
			}
		}
	}
	sort.Strings(overrides.order)
	var listing strings.Builder
	for _, symbol := range overrides.order {
		value := overrides.values[symbol]
		fmt.Fprintf(&listing, "%s=%s\n", symbol, value)
		if result.values[symbol] != "y" {
			result.set(symbol, value)
		}
	}
	if *report != "" {
		_ = os.WriteFile(*report, []byte(listing.String()), 0o644)
	}
	if *fragment != "" {
		result.load(readLines(*fragment), nil)
	}
	output := bufio.NewWriter(os.Stdout)
	for _, symbol := range result.order {
		if value := result.values[symbol]; value == "n" {
			_, _ = fmt.Fprintf(output, "# %s is not set\n", symbol)
		} else {
			_, _ = fmt.Fprintf(output, "%s=%s\n", symbol, value)
		}
	}
	_ = output.Flush()
}
