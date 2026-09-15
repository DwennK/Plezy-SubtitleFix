#!/usr/bin/env python3
"""Stage the Vulkan loader that Plezy already requires beside Windows libmpv.

The exact version, URL slug and archive hash are read from Windows/CMakeLists;
this adds no backend or dependency upgrade. It lets native probes load the DLL
on a CPU-only runner without relying on a GPU driver's system-wide loader.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def single(pattern, content):
    values = re.findall(pattern, content, re.DOTALL)
    if len(values) != 1:
        raise ValueError("Windows runtime pin layout changed; review CMake before adapting")
    return values[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    cmake = (ROOT / "windows/CMakeLists.txt").read_text()
    version = single(r'set\(VULKAN_RT_VERSION "([0-9.]+)"\)', cmake)
    block = single(r'set\(VULKAN_RT_SLUG "windows"\)(.*?)endif\(\)', cmake)
    checksum = single(r'set\(VULKAN_RT_SHA256 "([0-9a-f]{64})"\)', block)
    args.output.mkdir(parents=True, exist_ok=True)
    url = f"https://sdk.lunarg.com/sdk/download/{version}/windows/vulkan-runtime-components.zip"
    request = urllib.request.Request(url, headers={"User-Agent": "curl/8.4.0"})
    with tempfile.TemporaryDirectory(prefix="livesync-runtime-") as temporary:
        archive = Path(temporary) / "runtime.zip"
        digest = hashlib.sha256()
        size = 0
        with urllib.request.urlopen(request, timeout=60) as response, archive.open("wb") as output:
            while chunk := response.read(1024 * 1024):
                size += len(chunk)
                if size > 100 * 1024 * 1024:
                    raise ValueError("Runtime download exceeds the size safety bound")
                digest.update(chunk)
                output.write(chunk)
        if digest.hexdigest() != checksum:
            raise ValueError("Windows runtime archive hash mismatch")
        prefix = f"VulkanRT-X64-{version}-Components/"
        files = {"vulkan-1.dll": prefix + "x64/vulkan-1.dll",
                 "VulkanRT-License.txt": prefix + "VulkanRT-License.txt"}
        hashes = {}
        with zipfile.ZipFile(archive) as bundle:
            for target, member in files.items():
                data = bundle.read(member)
                hashes[target] = hashlib.sha256(data).hexdigest()
                pending = args.output / (target + ".partial")
                pending.write_bytes(data)
                pending.replace(args.output / target)
        (args.output / "livesync-runtime-provenance.json").write_text(json.dumps({
            "version": version, "archiveSha256": checksum, "files": hashes,
            "sourcePin": "windows/CMakeLists.txt", "architecture": "x86_64",
        }, indent=2) + "\n")
    print("Staged Plezy's pinned x64 Vulkan loader; no GPU availability claim.")


if __name__ == "__main__":
    main()
