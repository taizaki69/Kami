#!/usr/bin/env python3
"""Reproduce locked Kotlin fixtures with isolated, checksum-pinned tools.

Default mode uses existing downloads and verifies output without rewriting
fixtures. --fetch permits missing official distributions to be downloaded into
the supplied tools directory. CI tests consume checked-in fixtures directly.
"""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile


def digest(path, algorithm="sha256"):
    hasher = hashlib.new(algorithm)
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            hasher.update(chunk)
    return hasher.hexdigest()


def checked_file(path, sha256, size=None):
    if not path.is_file():
        raise ValueError(f"Missing file: {path.name}")
    if size is not None and path.stat().st_size != size:
        raise ValueError(f"Unexpected file size: {path.name}")
    if digest(path) != sha256:
        raise ValueError(f"SHA-256 mismatch: {path.name}")


def fetch_dependency(item, tools, allow_fetch):
    path = tools / item["name"]
    if not path.exists():
        if not allow_fetch:
            raise ValueError(f"Missing pinned dependency {path.name}; use --fetch explicitly.")
        request = urllib.request.Request(item["url"], headers={"User-Agent": "Kami-reference-fixture"})
        partial = path.with_name(path.name + ".partial")
        try:
            with urllib.request.urlopen(request, timeout=60) as response, partial.open("wb") as target:
                total = 0
                while chunk := response.read(1024 * 1024):
                    total += len(chunk)
                    if total > item["size"]:
                        raise ValueError(f"Oversized download: {path.name}")
                    target.write(chunk)
            checked_file(partial, item["sha256"], item["size"])
            if "sha512" in item and digest(partial, "sha512") != item["sha512"]:
                raise ValueError(f"SHA-512 mismatch: {path.name}")
            partial.rename(path)
        finally:
            partial.unlink(missing_ok=True)
    checked_file(path, item["sha256"], item["size"])
    if "sha512" in item and digest(path, "sha512") != item["sha512"]:
        raise ValueError(f"SHA-512 mismatch: {path.name}")
    return path


def checked_member_name(name):
    path = Path(name)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError("Unsafe distribution member path.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tools-dir", type=Path, required=True)
    parser.add_argument("--fetch", action="store_true")
    arguments = parser.parse_args()
    fixtures = Path(__file__).resolve().parent
    manifest = json.loads((fixtures / "manifest.json").read_text())
    tools = arguments.tools_dir.resolve()
    tools.mkdir(parents=True, exist_ok=True)
    producer = manifest["producer"]
    checked_file(fixtures / producer["sourcePath"], producer["sourceSHA256"])
    checked_file(Path(__file__).resolve(), producer["recipeSHA256"])
    dependencies = {
        item["name"]: fetch_dependency(item, tools, arguments.fetch)
        for item in manifest["dependencies"]
    }

    # Every run gets freshly extracted tools from verified archives; unrelated
    # files or old extracted jars in the tools directory cannot join classpaths.
    with tempfile.TemporaryDirectory(prefix="reference-build-", dir=tools) as temporary:
        work = Path(temporary)
        with tarfile.open(dependencies[producer["jreArchive"]]) as archive:
            for member in archive.getmembers():
                checked_member_name(member.name)
            archive.extractall(work / "jre", filter="data")
        with zipfile.ZipFile(dependencies[producer["compilerArchive"]]) as archive:
            for member in archive.infolist():
                checked_member_name(member.filename)
            archive.extractall(work / "kotlin")
        java = work / producer["javaRelativeExecutable"]
        lib = work / producer["compilerLibRelativePath"]
        classpath = ":".join(str(path) for path in [
            lib / "kotlin-stdlib.jar",
            *(dependencies[name] for name in producer["runtimeJarNames"]),
        ])
        jar = work / "reference-producer.jar"
        command = [
            str(java), "-cp", str(lib / "*"), "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
            "-no-stdlib", "-no-reflect", "-jvm-target", "17", "-classpath", classpath,
            "-Xplugin=" + str(lib / "kotlinx-serialization-compiler-plugin.jar"),
            "-d", str(jar), str(fixtures / producer["sourcePath"]),
        ]
        subprocess.run(command, check=True)
        generated = work / "generated"
        subprocess.run([
            str(java), "-cp", str(jar) + ":" + classpath, producer["mainClass"], str(generated),
        ], check=True)
        for fixture in manifest["fixtures"]:
            for path_key, hash_key in [
                ("rawPath", "rawSHA256"),
                ("gzipPath", "gzipSHA256"),
                ("expectedJSONPath", "expectedJSONSHA256"),
            ]:
                checked_file(generated / fixture[path_key], fixture[hash_key])
                checked_file(fixtures / fixture[path_key], fixture[hash_key])
        subprocess.run(["python3", str(fixtures / "verify-fixtures.py")], check=True)
    print(f"Reproduced {len(manifest['fixtures'])} fixtures; all locked outputs match.")


if __name__ == "__main__":
    main()
