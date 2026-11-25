"""This script requires Python 3.10.0 or higher to run."""

import configparser
import fnmatch
import hashlib
import logging
import os
import pathlib
import re
import xml.etree.ElementTree as Et
from typing import Any, Callable

alphanumeric_pattern = re.compile(r"(\d+)")

# Linux fork: specific local-only directories that must never enter the manifest are named in this environment
# variable instead of this published file. It takes a comma-separated list of directory names, matched
# case-insensitively at any depth. Directory names are deliberately not listed here, for privacy.
excluded_directories_env = "POB_MANIFEST_EXCLUDE_DIRS"


def _exclude_file(file_patterns: set[str], path: pathlib.Path) -> bool:
    """Whether to exclude a single file. Supports glob patterns (e.g., '*.scm')."""
    return any(fnmatch.fnmatch(path.name, pattern) for pattern in file_patterns)


def _exclude_directory(directory_names: set[str], path: pathlib.Path) -> bool:
    """Whether to exclude a directory. Doesn't consider any files in directories."""
    return any(
        len(path.parts) <= 1
        or all(a == b for a, b in zip(directory.split("/"), path.parts))
        for directory in directory_names
    )


def _parse_env_file(path: pathlib.Path) -> dict[str, str]:
    """Parse simple KEY=VALUE lines from a local .env file; a missing or unreadable file yields no entries."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return {}
    entries: dict[str, str] = {}
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if key.startswith("export "):
            key = key[len("export "):].strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        entries[key] = value
    return entries


def _parse_excluded_directories() -> set[str]:
    """Directory names to keep out of the manifest.

    Taken from the POB_MANIFEST_EXCLUDE_DIRS environment variable; when that is unset, a local .env file is used so
    the names stay out of this published file.
    """
    value = os.environ.get(excluded_directories_env)
    if value is None:
        value = _parse_env_file(pathlib.Path(".env")).get(excluded_directories_env, "")
    entries = (entry.strip().strip("/").lower() for entry in value.split(","))
    return {entry for entry in entries if entry}


def _is_excluded_path(path: pathlib.Path, excluded_directories: set[str]) -> bool:
    """Whether the path is one of, or inside one of, the excluded directories."""
    return any(part.lower() in excluded_directories for part in path.parts)


def _parse_list_option(config: configparser.ConfigParser, section: str, option: str) -> set[str]:
    """Split a comma-separated option into a cleaned set of entries."""
    if not config.has_option(section, option):
        return set()
    return {
        entry
        for entry in map(str.strip, config[section][option].split(","))
        if entry
    }


def _alphanumeric(key: str) -> list[int | str]:
    """Natural sorting order for numbers, e.g. 10 follows 9."""
    return [
        int(character) if character.isdigit() else character.lower()
        for character in re.split(alphanumeric_pattern, key)
    ]


def create_manifest(version: str | None = None, replace: bool = False) -> None:
    """Generate new SHA1 hashes and version number for Path of Building's manifest file.

    :param version: Three-part version number following https://semver.org/.
    :param replace: Whether to overwrite the existing manifest file.
    :return:
    """
    base_path = pathlib.Path().absolute()
    try:
        old_manifest = Et.parse(base_path / "manifest.xml")
    except FileNotFoundError:
        logging.critical(f"Manifest file not found in path '{base_path}'")
        return
    old_root = old_manifest.getroot()
    if (old_version := old_root.find("Version")) is None:
        logging.critical(f"Manifest file in {base_path} has no element 'Version'")
        return
    if (new_version := version or old_version.get("number")) is None:
        logging.critical(f"Manifest file in {base_path} has no attribute 'number'")
        return

    config = configparser.ConfigParser()
    try:
        config.read("manifest.cfg")
    except FileNotFoundError:
        logging.critical(f"Manifest configuration file not found in path '{base_path}'")
        return

    # Linux fork: installs update from this repository so they keep the Linux-aware updater.
    base_url = "https://raw.githubusercontent.com/grau-maus/PathOfBuilding-linux/{branch}/"
    parts: list[dict[str, str]] = []
    for part in config.sections():
        url = base_url + config[part]["path"]
        url_with_trailing_slash = url if url.endswith("/") else url + "/"
        attributes = (
            {"part": part, "platform": "win32", "url": url_with_trailing_slash}
            if part == "runtime"
            else {"part": part, "url": url_with_trailing_slash}
        )
        parts.append(attributes)

    files: list[dict[str, str]] = []
    excluded_directories = _parse_excluded_directories()
    for section in config.sections():
        include_files = _parse_list_option(config, section, "include-files")
        include_dirs = _parse_list_option(config, section, "include-directories")
        exclude_files = _parse_list_option(config, section, "exclude-files")
        exclude_dirs = _parse_list_option(config, section, "exclude-directories")
        source = pathlib.Path(config[section]["path"])
        for path in source.glob("**/*.*"):
            if _is_excluded_path(path, excluded_directories):
                continue
            if include_files and not _exclude_file(include_files, path):
                continue
            if include_dirs and not _exclude_directory(include_dirs, path):
                continue
            if exclude_files and _exclude_file(exclude_files, path):
                continue
            if exclude_dirs and _exclude_directory(exclude_dirs, path):
                continue
            data = path.read_bytes()
            # Normalize line endings for non-binary files in case they were accidentally mixed
            if b"\0" not in data:
                data = re.sub(rb"\r\n?|\n", b"\r\n", data)
            sha1 = hashlib.sha1(data).hexdigest()
            name = path.relative_to(config[section]["path"]).as_posix()
            attributes = (
                {"name": name, "part": section, "runtime": "win32", "sha1": sha1}
                if path.suffix in [".dll", ".exe"]
                else {"name": name, "part": section, "sha1": sha1}
            )
            files.append(attributes)

    files.sort(key=lambda attr: (attr["part"], _alphanumeric(attr["name"])))

    root = Et.Element("PoBVersion")
    Et.SubElement(root, "Version", number=new_version)
    for attributes in parts:
        Et.SubElement(root, "Source", attributes)
    for attributes in files:
        Et.SubElement(root, "File", attributes)
    file_name = "manifest.xml" if replace else "manifest-updated.xml"
    tree = Et.ElementTree(root)
    Et.indent(tree, "\t")
    tree.write(base_path / file_name, encoding="UTF-8", xml_declaration=True)
    if version is not None:
        logging.info(f"Updated to version {version}")


def cli() -> None:
    """CLI for conveniently updating Path of Building's manifest file."""
    import argparse

    parser = argparse.ArgumentParser(
        usage="%(prog)s [options]",
        description="Update Path of Building's manifest file for a new release.",
        allow_abbrev=False,
    )
    parser.add_argument("--version", action="version", version="2.0.0")
    logging_level = parser.add_mutually_exclusive_group()
    logging_level.add_argument(
        "-v", "--verbose", action="store_true", help="Print more logging information"
    )
    logging_level.add_argument(
        "-q", "--quiet", action="store_true", help="Print no logging information"
    )
    parser.add_argument("--in-place", action="store_true", help="Replace original file")
    parser.add_argument(
        "--set-version",
        action="store",
        help="Set manifest version number",
        metavar="SEMVER",
    )
    args = parser.parse_args()
    if args.verbose:
        logging.basicConfig(level=logging.INFO)
    elif args.quiet:
        logging.basicConfig(level=logging.CRITICAL + 1)
    create_manifest(args.set_version or None, args.in_place)


if __name__ == "__main__":
    cli()
