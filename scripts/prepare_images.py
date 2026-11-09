#!/usr/bin/env python3
"""Reassemble bundled QCOW2 parts and verify MD5 before atomic publication."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import sys
import tempfile


IOSVL2_NAME = "vios_l2-adventerprisek9-m.ssa.high_iron_20200929.qcow2"
IOSVL2_MD5 = "99ecab32de12410c533e6abd4e9710aa"
IOSVL2_PART_SIZES = (31457280, 31457280, 27495424)
PART_NAME = re.compile(r"^(.*\.qcow2)\.part([0-9]{2})$")
BLOCK_SIZE = 1024 * 1024


def file_md5(path):
    digest = hashlib.md5(usedforsecurity=False)
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(BLOCK_SIZE), b""):
            digest.update(block)
    return digest.hexdigest()


def expected_md5(image):
    for candidate in (Path(str(image) + ".md5"), image.with_suffix(".md5")):
        if candidate.is_file():
            hashes = re.findall(r"\b[0-9a-fA-F]{32}\b", candidate.read_text(encoding="utf-8"))
            if len(set(value.lower() for value in hashes)) != 1:
                raise ValueError(f"В {candidate} должна быть одна контрольная сумма MD5.")
            value = hashes[0].lower()
            if image.name == IOSVL2_NAME and value != IOSVL2_MD5:
                raise ValueError(f"Контрольная сумма {candidate} конфликтует с реестром IOSvL2.")
            return value
    raise ValueError(f"Нет соседнего .md5 для {image.name}.")


def prepare_image(image, parts):
    """Return True after assembly, False when an existing image is verified."""
    expected = expected_md5(image)
    if image.is_file() and file_md5(image) == expected:
        print(f"[OK] Образ уже собран, MD5 проверен: {image}")
        return False
    if not parts:
        raise ValueError(f"Образ {image.name} повреждён, а частей для восстановления нет.")
    numbered = []
    for part in parts:
        match = PART_NAME.fullmatch(part.name)
        if match is None or match.group(1) != image.name:
            raise ValueError(f"Некорректное имя части: {part.name}.")
        numbered.append((int(match.group(2)), part))
    numbered.sort()
    if [number for number, _ in numbered] != list(range(1, len(numbered) + 1)):
        raise ValueError(f"Неполный набор частей {image.name}: нужны part01..partNN без пропусков.")
    if image.name == IOSVL2_NAME:
        if len(numbered) != len(IOSVL2_PART_SIZES):
            raise ValueError(f"Для {image.name} необходимы ровно три части: part01, part02, part03.")
        if tuple(part.stat().st_size for _, part in numbered) != IOSVL2_PART_SIZES:
            raise ValueError(f"Неверный размер частей {image.name}; повторите скачивание комплекта.")

    temp_path = None
    try:
        digest = hashlib.md5(usedforsecurity=False)
        with tempfile.NamedTemporaryFile(
            prefix=f".{image.name}.", suffix=".assembling", dir=image.parent, delete=False
        ) as destination:
            temp_path = Path(destination.name)
            for _, part in numbered:
                with part.open("rb") as source:
                    for block in iter(lambda: source.read(BLOCK_SIZE), b""):
                        destination.write(block)
                        digest.update(block)
            destination.flush()
            os.fsync(destination.fileno())
        if digest.hexdigest() != expected:
            raise ValueError(f"MD5 собранного {image.name} не совпал: части повреждены или неполны.")
        os.replace(temp_path, image)
        print(f"[OK] Образ собран из {len(numbered)} частей, MD5 проверен: {image}")
        return True
    finally:
        if temp_path is not None and temp_path.exists():
            temp_path.unlink()


def prepare_images(images_dir):
    groups = {}
    for part in images_dir.rglob("*.qcow2.part*"):
        if not part.is_file():
            continue
        match = PART_NAME.fullmatch(part.name)
        if match is None:
            raise ValueError(f"Некорректное имя части: {part.name}.")
        image = part.with_name(match.group(1))
        groups.setdefault(image, []).append(part)
    # Also verify an existing stock image when a local kit contains no parts.
    for image in images_dir.rglob(IOSVL2_NAME):
        if image.is_file():
            groups.setdefault(image, [])
    for image in sorted(groups):
        prepare_image(image, groups[image])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--images-dir", type=Path, default=Path(__file__).resolve().parents[1] / "images")
    args = parser.parse_args()
    try:
        prepare_images(args.images_dir)
    except (OSError, ValueError) as error:
        print(f"[ERROR] Не удалось подготовить образы: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
