"""Fail closed if an app keyboard product reaches anything beyond the three light targets."""

import json
from pathlib import Path
import re
import subprocess
import sys


ALLOWED_TARGETS = {"PikoKit", "PikoBridge", "PikoUI"}
ALLOWED_PRODUCTS = ALLOWED_TARGETS | {"PikoKeyboardKit"}


def check_package(manifest, keyboard_products):
    products = {product["name"]: product["targets"] for product in manifest["products"]}
    targets = {target["name"]: target["dependencies"] for target in manifest["targets"]}
    visited = set()

    def visit(name):
        if name not in ALLOWED_TARGETS or name not in targets:
            raise ValueError(f"Keyboard reaches forbidden target: {name}")
        if name in visited:
            return
        visited.add(name)
        for dependency in targets[name]:
            if "byName" in dependency:
                visit(dependency["byName"][0])
            elif "target" in dependency:
                visit(dependency["target"][0])
            else:
                raise ValueError(f"Keyboard reaches external/unknown dependency: {dependency}")

    # Guard the exported keyboard product even when the app lists individual products.
    for product in set(keyboard_products) | {"PikoKeyboardKit"}:
        if product not in ALLOWED_PRODUCTS or product not in products:
            raise ValueError(f"Keyboard links forbidden product: {product}")
        for target in products[product]:
            visit(target)
    return sorted(visited)


def main():
    root = Path(__file__).resolve().parents[1]
    project = (root / "App/project.yml").read_text()
    keyboard = project.split("  PikoKeyboard:", 1)[1].split("  PikoWidgets:", 1)[0]
    packages = re.findall(r"^\s+- package:\s*(\w+)\s*$", keyboard, re.MULTILINE)
    products = re.findall(r"^\s+products:\s*\[([^\]]*)\]\s*$", keyboard, re.MULTILINE)
    if packages != ["Piko"] or len(products) != 1 or re.search(
        r"^\s+- (?:target|framework|sdk|carthage):", keyboard, re.MULTILINE
    ):
        raise ValueError("Unexpected keyboard dependency layout; review the light-target guard")
    keyboard_products = [name.strip().strip("\"'") for name in products[0].split(",")]
    result = subprocess.run(
        ["swift", "package", "dump-package"],
        cwd=root,
        check=True,
        stdout=subprocess.PIPE,
        text=True,
        timeout=60,
    )
    reached = check_package(json.loads(result.stdout), keyboard_products)
    print(f"keyboard dependency closure is clean: {', '.join(reached)}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, IndexError, subprocess.SubprocessError) as error:
        sys.exit(f"Keyboard dependency guard failed: {error}")
