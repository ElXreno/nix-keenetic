package main

import (
	"archive/tar"
	"compress/gzip"
	"io"
	"os"
	"path/filepath"
	"strings"
)

func realPath(name string) (string, error) {
	resolved, err := filepath.EvalSymlinks(name)
	if err != nil {
		return "", err
	}
	return filepath.Abs(resolved)
}

func unpackArchives(directory, target string) bool {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return false
	}
	ok := true
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasSuffix(name, ".tar.gz") && !strings.HasSuffix(name, ".tgz") {
			continue
		}
		logbook.write(levelInfo, "npkg", nfmt(`inflating "%1".`, name))
		if err := unpackArchive(directory+name, target); err != nil {
			logbook.write(levelError, "npkg", nfmt(`failed to inflate "%1": %2.`, name, errorString(err)))
			ok = false
		}
	}
	return ok
}

func unpackArchive(archive, target string) error {
	file, err := os.Open(archive)
	if err != nil {
		return err
	}
	defer func() { _ = file.Close() }()
	stream, err := gzip.NewReader(file)
	if err != nil {
		return err
	}
	reader := tar.NewReader(stream)
	for {
		header, err := reader.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		destination := filepath.Join(target, filepath.Clean("/"+header.Name))
		mode := os.FileMode(header.Mode).Perm()
		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(destination, mode|0o700); err != nil {
				return err
			}
		case tar.TypeSymlink:
			_ = os.Remove(destination)
			if err := os.Symlink(header.Linkname, destination); err != nil {
				return err
			}
		case tar.TypeReg:
			_ = os.MkdirAll(filepath.Dir(destination), 0o755)
			_ = os.Remove(destination)
			output, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, mode)
			if err != nil {
				return err
			}
			_, copyErr := io.Copy(output, reader)
			closeErr := output.Close()
			if copyErr != nil {
				return copyErr
			}
			if closeErr != nil {
				return closeErr
			}
			_ = os.Chmod(destination, mode)
		}
	}
}
