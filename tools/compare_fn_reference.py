#!/usr/bin/env python3
"""Build visual alignment evidence for separately captured KnockNight clips.

This tool compares source imagery. It never changes poses, infers landmarks, or
reports a visual/pose match score. Reference and game frames are selected on
the same normalized time axis, and every target/selected time is recorded.
"""

from __future__ import annotations

import argparse
import html
import json
import math
import re
import shutil
import statistics
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Sequence

from PIL import Image, ImageDraw, ImageFont, ImageOps


IMAGE_EXTENSIONS = {
    ".bmp",
    ".jpeg",
    ".jpg",
    ".png",
    ".tif",
    ".tiff",
    ".webp",
}
VIDEO_EXTENSIONS = {
    ".avi",
    ".m2ts",
    ".m4v",
    ".mkv",
    ".mov",
    ".mp4",
    ".mts",
    ".webm",
}


@dataclass(frozen=True)
class Phase:
    phase_id: str
    label: str
    normalized_time: float
    description: str


# These six samples cover the required guard -> entry -> peak -> hold ->
# release -> guard cycle. Slightly inset endpoints avoid selecting frames
# beyond the caller's clip window at duration boundaries.
PHASES: tuple[Phase, ...] = (
    Phase("guard_settle", "GUARD / SETTLE", 0.02, "Initial guard and body set"),
    Phase("entry", "ENTRY", 0.20, "Start of the guard entry motion"),
    Phase("peak", "PEAK", 0.40, "Maximum extension or most exposed pose"),
    Phase("hold", "HOLD", 0.60, "Sustained peak or contact hold"),
    Phase("release", "RELEASE", 0.80, "Beginning of the return motion"),
    Phase("guard_return", "GUARD / RETURN", 0.98, "Return to the settled guard"),
)


@dataclass(frozen=True)
class SourceFrame:
    index: int
    path: Path
    seconds: float


@dataclass(frozen=True)
class Selection:
    frame: SourceFrame
    target_seconds: float
    offset_seconds: float


class ComparisonError(RuntimeError):
    """A user-actionable input or output failure."""


def natural_key(path: Path) -> list[Any]:
    """Sort frame names numerically while remaining deterministic elsewhere."""
    return [int(part) if part.isdigit() else part.casefold() for part in re.split(r"(\d+)", path.name)]


def parse_crop(value: str) -> tuple[int, int, int, int]:
    parts = [part.strip() for part in value.split(",")]
    if len(parts) != 4:
        raise argparse.ArgumentTypeError("crop must be x,y,w,h in source-frame pixels")
    try:
        x, y, width, height = (int(part) for part in parts)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("crop values must be integers") from exc
    if x < 0 or y < 0 or width <= 0 or height <= 0:
        raise argparse.ArgumentTypeError("crop requires x>=0, y>=0, w>0, h>0")
    return x, y, width, height


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Create visual-only reference/game key-phase strips, an animated GIF, "
            "and a timing manifest for KnockNight Fight Night review."
        )
    )
    parser.add_argument("--reference", required=True, type=Path, help="reference video or frame directory")
    parser.add_argument("--game", required=True, type=Path, help="game frame directory")
    parser.add_argument("--out", required=True, type=Path, help="absolute output directory")
    parser.add_argument("--ref-start", type=float, default=0.0, help="reference source start in seconds (default: 0)")
    parser.add_argument("--ref-duration", required=True, type=float, help="comparison window in seconds")
    parser.add_argument("--fps", type=float, default=12.0, help="reference extraction/sampling fps (default: 12)")
    parser.add_argument("--game-start", type=float, default=0.2, help="game source start in seconds (default: 0.2)")
    parser.add_argument("--ref-crop", type=parse_crop, help="reference crop x,y,w,h in source pixels")
    parser.add_argument("--game-crop", type=parse_crop, help="game crop x,y,w,h in source pixels")
    parser.add_argument("--mirror-ref", action="store_true", help="flip the whole cropped reference frame")
    parser.add_argument("--landmarks", type=Path, help="optional annotated normalized landmark JSON")
    parser.add_argument("--phase-times", help="six increasing normalized timestamps for guard, entry, peak, hold, release, return")
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="replace this tool's known artifacts in an existing output directory",
    )
    return parser


def validate_args(parser: argparse.ArgumentParser, args: argparse.Namespace) -> None:
    if not args.out.is_absolute():
        parser.error("--out must be an absolute path")
    if not math.isfinite(args.ref_start) or args.ref_start < 0:
        parser.error("--ref-start must be a finite value >= 0")
    if not math.isfinite(args.ref_duration) or args.ref_duration <= 0:
        parser.error("--ref-duration must be a finite value > 0")
    if not math.isfinite(args.fps) or args.fps <= 0:
        parser.error("--fps must be a finite value > 0")
    if not math.isfinite(args.game_start) or args.game_start < 0:
        parser.error("--game-start must be a finite value >= 0")


def prepare_output_dir(out_dir: Path, overwrite: bool) -> None:
    out_dir = out_dir.resolve()
    if out_dir.exists() and not out_dir.is_dir():
        raise ComparisonError(f"output path exists and is not a directory: {out_dir}")

    known_root_files = {
        "comparison.gif",
        "gallery.html",
        "key_phases.png",
        "landmark_measurements.json",
        "manifest.json",
        "summary.json",
        "summary.txt",
    }
    known_dirs = {"reference_frames", "strips"}

    if out_dir.exists():
        entries = list(out_dir.iterdir())
        if entries and not overwrite:
            raise ComparisonError(
                f"output directory is not empty: {out_dir}. Choose a new --out or pass --overwrite."
            )
        if overwrite:
            for entry in entries:
                if entry.name in known_root_files and entry.is_file():
                    entry.unlink()
                elif entry.name in known_dirs and entry.is_dir():
                    resolved = entry.resolve()
                    if resolved.parent != out_dir:
                        raise ComparisonError(f"refusing to remove unexpected output path: {resolved}")
                    shutil.rmtree(resolved)

    out_dir.mkdir(parents=True, exist_ok=True)


def collect_frame_directory(directory: Path) -> list[Path]:
    if not directory.is_dir():
        raise ComparisonError(f"frame directory does not exist: {directory}")
    capture_manifest = directory / "sequence_manifest.json"
    if capture_manifest.is_file():
        data = json.loads(capture_manifest.read_text(encoding="utf-8-sig"))
        paths = [Path(row["image"]) for row in data.get("frames", [])]
        if paths and all(path.is_file() for path in paths):
            return paths
    frames = [
        path
        for path in directory.iterdir()
        if path.is_file() and path.suffix.casefold() in IMAGE_EXTENSIONS
    ]
    frames.sort(key=natural_key)
    if not frames:
        raise ComparisonError(f"no supported image frames found in: {directory}")
    return frames


def extract_reference_video(
    video_path: Path,
    extraction_dir: Path,
    start_seconds: float,
    duration_seconds: float,
    fps: float,
) -> tuple[list[Path], list[str]]:
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise ComparisonError("ffmpeg is required when --reference is a video")

    extraction_dir.mkdir(parents=True, exist_ok=False)
    output_pattern = extraction_dir / "frame_%06d.png"
    command = [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-ss",
        f"{start_seconds:.6f}",
        "-i",
        str(video_path),
        "-t",
        f"{duration_seconds:.6f}",
        "-vf",
        f"fps={fps:.12g}",
        "-an",
        "-start_number",
        "0",
        str(output_pattern),
    ]
    completed = subprocess.run(command, capture_output=True, text=True, check=False)
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "ffmpeg exited without details").strip()
        raise ComparisonError(f"reference extraction failed: {detail[-1600:]}")

    frames = collect_frame_directory(extraction_dir)
    return frames, command


def frames_with_times(paths: Sequence[Path], base_seconds: float, fps: float) -> list[SourceFrame]:
    return [
        SourceFrame(index=index, path=path, seconds=base_seconds + index / fps)
        for index, path in enumerate(paths)
    ]


def nearest_frame(frames: Sequence[SourceFrame], target_seconds: float) -> Selection:
    selected = min(frames, key=lambda frame: (abs(frame.seconds - target_seconds), frame.index))
    return Selection(
        frame=selected,
        target_seconds=target_seconds,
        offset_seconds=selected.seconds - target_seconds,
    )


def key_phase_selections(
    frames: Sequence[SourceFrame], source_start: float, duration: float
) -> list[tuple[Phase, Selection]]:
    return [
        (phase, nearest_frame(frames, source_start + phase.normalized_time * duration))
        for phase in PHASES
    ]


def animation_selections(
    frames: Sequence[SourceFrame], source_start: float, duration: float, fps: float
) -> list[Selection]:
    sample_count = max(1, int(round(duration * fps)))
    return [nearest_frame(frames, source_start + index / fps) for index in range(sample_count)]


def selection_manifest(selection: Selection, source_origin: float, fps: float) -> dict[str, Any]:
    path = selection.frame.path
    return {
        "target_source_seconds": round(selection.target_seconds, 9),
        "selected_frame": path.name,
        "selected_frame_index": selection.frame.index,
        "selected_source_seconds": round(selection.frame.seconds, 9),
        "selected_source_seconds_from_origin": round(selection.frame.seconds - source_origin, 9),
        "offset_seconds": round(selection.offset_seconds, 9),
        "offset_frames_at_fps": round(selection.offset_seconds * fps, 6),
    }


def load_font(size: int, bold: bool = False) -> ImageFont.ImageFont | ImageFont.FreeTypeFont:
    candidates = [
        Path("C:/Windows/Fonts/segoeuib.ttf" if bold else "C:/Windows/Fonts/segoeui.ttf"),
        Path("C:/Windows/Fonts/arialbd.ttf" if bold else "C:/Windows/Fonts/arial.ttf"),
        Path("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"),
    ]
    for candidate in candidates:
        if candidate.is_file():
            return ImageFont.truetype(str(candidate), size=size)
    return ImageFont.load_default(size=size)


def open_prepared_frame(
    path: Path, crop: tuple[int, int, int, int] | None, mirror: bool
) -> tuple[Image.Image, tuple[int, int], tuple[int, int]]:
    try:
        with Image.open(path) as source:
            image = source.convert("RGB")
    except Exception as exc:
        raise ComparisonError(f"could not read frame {path}: {exc}") from exc

    source_size = image.size
    if crop is not None:
        x, y, width, height = crop
        if x + width > source_size[0] or y + height > source_size[1]:
            raise ComparisonError(
                f"crop {crop} does not fit frame {path.name} ({source_size[0]}x{source_size[1]})"
            )
        image = image.crop((x, y, x + width, y + height))
    if mirror:
        image = ImageOps.mirror(image)
    return image, source_size, image.size


def seconds_label(value: float) -> str:
    return f"{value:.3f}s"


def offset_label(value: float, fps: float) -> str:
    return f"{value:+.3f}s ({value * fps:+.2f}f)"


def draw_text_fit(
    draw: ImageDraw.ImageDraw,
    box: tuple[int, int, int, int],
    text: str,
    font: ImageFont.ImageFont | ImageFont.FreeTypeFont,
    fill: str,
    anchor: str = "la",
) -> None:
    draw.text(box[:2], text, font=font, fill=fill, anchor=anchor)


def pair_canvas(
    ref_image: Image.Image,
    game_image: Image.Image,
    heading: str,
    detail_lines: Sequence[str],
    footer: str,
    panel_size: tuple[int, int],
    *,
    margin: int,
    gap: int,
    heading_size: int,
    label_size: int,
    detail_size: int,
    footer_size: int,
) -> Image.Image:
    panel_width, panel_height = panel_size
    heading_height = max(34, heading_size + 18)
    label_height = max(24, label_size + 10)
    detail_height = max(20, detail_size + 6) * len(detail_lines)
    footer_height = max(34, footer_size + 18)
    width = margin * 2 + panel_width * 2 + gap
    height = margin * 2 + heading_height + label_height + panel_height + detail_height + footer_height
    canvas = Image.new("RGB", (width, height), "#0c1117")
    draw = ImageDraw.Draw(canvas)
    heading_font = load_font(heading_size, bold=True)
    label_font = load_font(label_size, bold=True)
    detail_font = load_font(detail_size)
    footer_font = load_font(footer_size)

    draw.rectangle((0, 0, width, heading_height + margin // 2), fill="#17212c")
    draw_text_fit(draw, (margin, margin // 2 + 2), heading, heading_font, "#f4c95d")

    y = margin + heading_height
    left_x = margin
    right_x = margin + panel_width + gap
    draw_text_fit(draw, (left_x, y), "REFERENCE · ACTUAL SOURCE FRAME", label_font, "#7fd1ff")
    draw_text_fit(draw, (right_x, y), "GAME · ACTUAL CAPTURE FRAME", label_font, "#8ee59a")
    y += label_height

    for x, image, border in (
        (left_x, ref_image, "#28627a"),
        (right_x, game_image, "#2d6b39"),
    ):
        draw.rectangle((x, y, x + panel_width, y + panel_height), fill="#05080b", outline=border, width=2)
        fitted = ImageOps.contain(image, (panel_width - 4, panel_height - 4), Image.Resampling.LANCZOS)
        paste_x = x + (panel_width - fitted.width) // 2
        paste_y = y + (panel_height - fitted.height) // 2
        canvas.paste(fitted, (paste_x, paste_y))
    y += panel_height + 8

    for line in detail_lines:
        draw_text_fit(draw, (margin, y), line, detail_font, "#d8e0e8")
        y += detail_height // max(1, len(detail_lines))

    draw.line((margin, height - footer_height, width - margin, height - footer_height), fill="#2b3947", width=1)
    draw_text_fit(
        draw,
        (margin, height - footer_height + 9),
        footer,
        footer_font,
        "#9eabb8",
    )
    return canvas


def render_phase_strips(
    out_dir: Path,
    ref_phases: Sequence[tuple[Phase, Selection]],
    game_phases: Sequence[tuple[Phase, Selection]],
    ref_crop: tuple[int, int, int, int] | None,
    game_crop: tuple[int, int, int, int] | None,
    mirror_ref: bool,
    fps: float,
    warnings: list[str],
) -> tuple[list[dict[str, Any]], list[Path], dict[str, tuple[int, int]]]:
    strips_dir = out_dir / "strips"
    strips_dir.mkdir(parents=True, exist_ok=True)
    records: list[dict[str, Any]] = []
    files: list[Path] = []
    prepared_sizes: dict[str, tuple[int, int]] = {}

    for index, ((phase, ref_sel), (_, game_sel)) in enumerate(zip(ref_phases, game_phases), start=1):
        ref_image, ref_source_size, ref_crop_size = open_prepared_frame(
            ref_sel.frame.path, ref_crop, mirror_ref
        )
        game_image, game_source_size, game_crop_size = open_prepared_frame(
            game_sel.frame.path, game_crop, False
        )
        prepared_sizes.setdefault("reference", ref_crop_size)
        prepared_sizes.setdefault("game", game_crop_size)

        detail_lines = (
            f"normalized {phase.normalized_time:.3f}  |  REF target {seconds_label(ref_sel.target_seconds)}  "
            f"frame {ref_sel.frame.path.name} at {seconds_label(ref_sel.frame.seconds)}  "
            f"offset {offset_label(ref_sel.offset_seconds, fps)}",
            f"                                  |  GAME target {seconds_label(game_sel.target_seconds)}  "
            f"frame {game_sel.frame.path.name} at {seconds_label(game_sel.frame.seconds)}  "
            f"offset {offset_label(game_sel.offset_seconds, fps)}",
        )
        canvas = pair_canvas(
            ref_image,
            game_image,
            f"{index:02d} / {len(PHASES):02d}  ·  {phase.label}  ·  {phase.description}",
            detail_lines,
            "Visual alignment evidence only. Whole-frame crop/scale/flip is allowed; no pose match score is inferred.",
            (760, 430),
            margin=20,
            gap=14,
            heading_size=25,
            label_size=16,
            detail_size=14,
            footer_size=14,
        )
        strip_path = strips_dir / f"{index:02d}_{phase.phase_id}.png"
        canvas.save(strip_path, format="PNG", optimize=True)
        files.append(strip_path)

        records.append(
            {
                "index": index,
                "phase_id": phase.phase_id,
                "label": phase.label,
                "description": phase.description,
                "normalized_time": phase.normalized_time,
                "reference": {
                    **selection_manifest(ref_sel, ref_sel.frame.seconds - ref_sel.frame.index / fps, fps),
                    "source_frame_size": list(ref_source_size),
                    "prepared_frame_size": list(ref_crop_size),
                },
                "game": {
                    **selection_manifest(game_sel, game_sel.frame.seconds - game_sel.frame.index / fps, fps),
                    "source_frame_size": list(game_source_size),
                    "prepared_frame_size": list(game_crop_size),
                },
                "strip": strip_path.relative_to(out_dir).as_posix(),
            }
        )

    # A single contact sheet makes the six phase pairs easy to scan outside HTML.
    loaded = []
    for path in files:
        with Image.open(path) as source:
            loaded.append(source.convert("RGB"))
    width = max(image.width for image in loaded)
    contact_height = sum(image.height for image in loaded) + 8 * (len(loaded) - 1)
    contact = Image.new("RGB", (width, contact_height), "#081018")
    y = 0
    for image in loaded:
        contact.paste(image, (0, y))
        y += image.height + 8
    contact_path = out_dir / "key_phases.png"
    contact.save(contact_path, format="PNG", optimize=True)
    files.append(contact_path)

    unique_ref = len({record["reference"]["selected_frame"] for record in records})
    unique_game = len({record["game"]["selected_frame"] for record in records})
    if unique_ref < len(PHASES):
        warnings.append(
            f"Key phases selected only {unique_ref} unique reference frames at {fps:g} fps; "
            "the clip may be too short for six distinct phase samples."
        )
    if unique_game < len(PHASES):
        warnings.append(
            f"Key phases selected only {unique_game} unique game frames at {fps:g} fps; "
            "the capture directory may be too short or the fps may be wrong."
        )

    return records, files, prepared_sizes


def render_animation(
    out_dir: Path,
    ref_samples: Sequence[Selection],
    game_samples: Sequence[Selection],
    game_start: float,
    ref_crop: tuple[int, int, int, int] | None,
    game_crop: tuple[int, int, int, int] | None,
    mirror_ref: bool,
    duration: float,
    fps: float,
) -> tuple[dict[str, Any], Path]:
    gif_frames: list[Image.Image] = []
    sample_records: list[dict[str, Any]] = []
    for index, (ref_sel, game_sel) in enumerate(zip(ref_samples, game_samples)):
        ref_image, _, _ = open_prepared_frame(ref_sel.frame.path, ref_crop, mirror_ref)
        game_image, _, _ = open_prepared_frame(game_sel.frame.path, game_crop, False)
        normalized = (index / fps) / duration
        canvas = pair_canvas(
            ref_image,
            game_image,
            f"MATCHED NORMALIZED TIME  ·  t={seconds_label(index / fps)}  ·  norm={normalized:.4f}",
            (
                f"REF {ref_sel.frame.path.name} at {seconds_label(ref_sel.frame.seconds)} · "
                f"target {seconds_label(ref_sel.target_seconds)} · offset {offset_label(ref_sel.offset_seconds, fps)}",
                f"GAME {game_sel.frame.path.name} at {seconds_label(game_sel.frame.seconds)} · "
                f"target {seconds_label(game_sel.target_seconds)} · offset {offset_label(game_sel.offset_seconds, fps)}",
            ),
            "Visual alignment evidence only; no automatic 1:1 or pose-match claim.",
            (440, 285),
            margin=12,
            gap=10,
            heading_size=17,
            label_size=12,
            detail_size=11,
            footer_size=11,
        )
        gif_frames.append(
            canvas.quantize(colors=128, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.FLOYDSTEINBERG)
        )
        sample_records.append(
            {
                "sample_index": index,
                "normalized_time": round(normalized, 9),
                "local_seconds": round(index / fps, 9),
                "reference": selection_manifest(ref_sel, ref_sel.frame.seconds - ref_sel.frame.index / fps, fps),
                "game": selection_manifest(game_sel, game_sel.frame.seconds - game_sel.frame.index / fps, fps),
            }
        )

    gif_path = out_dir / "comparison.gif"
    duration_ms = max(20, int(round(1000.0 / fps)))
    first, *remaining = gif_frames
    first.save(
        gif_path,
        format="GIF",
        save_all=True,
        append_images=remaining,
        duration=duration_ms,
        loop=0,
        optimize=False,
        disposal=2,
    )
    animation_manifest = {
        "file": gif_path.name,
        "format": "animated GIF",
        "fps": fps,
        "frame_duration_ms": duration_ms,
        "sample_count": len(gif_frames),
        "unique_reference_frames": len({item.frame.path for item in ref_samples}),
        "unique_game_frames": len({item.frame.path for item in game_samples}),
        "samples": sample_records,
    }
    return animation_manifest, gif_path


def _normalized_key(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", value.casefold())


def _phase_lookup(records: Any) -> dict[str, dict[str, Any]]:
    if isinstance(records, dict):
        if "frames" in records and isinstance(records["frames"], (dict, list)):
            records = records["frames"]
        else:
            return {
                _normalized_key(str(key)): value
                for key, value in records.items()
                if isinstance(value, dict)
            }
    if isinstance(records, list):
        result: dict[str, dict[str, Any]] = {}
        for item in records:
            if not isinstance(item, dict):
                continue
            key = item.get("phase", item.get("phase_id", item.get("id", item.get("key"))))
            if key is not None:
                result[_normalized_key(str(key))] = item
        return result
    raise ValueError("each landmark source must be an object or a list of phase records")


def _find_phase_record(records: dict[str, dict[str, Any]], phase: Phase, index: int) -> dict[str, Any] | None:
    aliases = [
        phase.phase_id,
        phase.label,
        f"{index}",
        f"{index + 1}",
        f"phase{index + 1}",
    ]
    for alias in aliases:
        record = records.get(_normalized_key(alias))
        if record is not None:
            return record
    return None


def _coordinate_from_value(value: Any) -> tuple[float, float] | None:
    if value is None:
        return None
    if isinstance(value, dict) and "x" in value and "y" in value:
        value = [value["x"], value["y"]]
    if not isinstance(value, (list, tuple)) or len(value) != 2:
        raise ValueError("landmark point must be [x,y] normalized coordinates")
    x, y = value
    if isinstance(x, bool) or isinstance(y, bool):
        raise ValueError("landmark point coordinates must be numbers")
    try:
        x_value, y_value = float(x), float(y)
    except (TypeError, ValueError) as exc:
        raise ValueError("landmark point coordinates must be numbers") from exc
    if not math.isfinite(x_value) or not math.isfinite(y_value):
        raise ValueError("landmark coordinates must be finite")
    if not (0.0 <= x_value <= 1.0 and 0.0 <= y_value <= 1.0):
        raise ValueError("normalized landmark coordinates must be within 0..1")
    return x_value, y_value


def _distance(first: tuple[float, float], second: tuple[float, float], aspect: float) -> float:
    return math.hypot((second[0] - first[0]) * aspect, second[1] - first[1])


def _extract_side_points(
    side_data: Any, aspect: float
) -> tuple[dict[str, list[tuple[float, float] | None]], list[str]]:
    records = _phase_lookup(side_data)
    points: dict[str, list[tuple[float, float] | None]] = {group: [] for group in ("head", "hip", "knee")}
    issues: list[str] = []
    aliases = {"head": ("head", "head_point"), "hip": ("hip", "hips", "hip_point"), "knee": ("knee", "knees", "knee_point")}
    for index, phase in enumerate(PHASES):
        record = _find_phase_record(records, phase, index)
        for group in ("head", "hip", "knee"):
            value = None
            if record is not None:
                for field in aliases[group]:
                    if field in record:
                        value = record[field]
                        break
            try:
                points[group].append(_coordinate_from_value(value))
            except ValueError as exc:
                issues.append(f"{phase.phase_id}.{group}: {exc}")
                points[group].append(None)
    return points, issues


def _group_measure(
    group: str,
    side_points: dict[str, list[tuple[float, float] | None]],
    body_span: float | None,
    aspect: float,
) -> dict[str, Any]:
    points = side_points[group]
    missing = [phase.phase_id for phase, point in zip(PHASES, points) if point is None]
    if body_span is None or body_span <= 1e-9:
        return {
            "status": "unavailable",
            "normalized_path_length": None,
            "missing_phases": missing,
            "reason": "head/hip body-scale baseline is unavailable or zero",
        }

    total = 0.0
    usable_segments = 0
    previous: tuple[float, float] | None = None
    for point in points:
        if point is None:
            previous = None
            continue
        if previous is not None:
            total += _distance(previous, point, aspect)
            usable_segments += 1
        previous = point

    if usable_segments == 0:
        return {
            "status": "unavailable",
            "normalized_path_length": None,
            "missing_phases": missing,
            "reason": "fewer than two consecutive supplied coordinates",
        }

    return {
        "status": "partial" if missing else "available",
        "normalized_path_length": round(total / body_span, 9),
        "missing_phases": missing,
        "usable_segments": usable_segments,
    }


def landmark_measurements(
    landmarks_path: Path | None,
    reference_aspect: float,
    game_aspect: float,
) -> dict[str, Any]:
    base = {
        "kind": "normalized displacement ratios only; not a pose-match score",
        "coordinate_space": "normalized x/y after crop, mirror-ref, before contain scaling",
        "normalization": "path length divided by that side's median head-to-hip body span",
        "input": str(landmarks_path) if landmarks_path else None,
    }
    if landmarks_path is None:
        return {
            **base,
            "status": "unavailable",
            "reason": "No --landmarks file was supplied. No pose metric was inferred from pixels.",
        }
    if not landmarks_path.is_file():
        raise ComparisonError(f"landmark file does not exist: {landmarks_path}")
    try:
        data = json.loads(landmarks_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ComparisonError(f"could not read landmark JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise ComparisonError("landmark JSON root must be an object")
    coordinate_space = data.get("coordinate_space", "normalized")
    if coordinate_space not in {"normalized", "normalized_post_crop"}:
        raise ComparisonError(
            "landmark coordinate_space must be 'normalized' or 'normalized_post_crop'; "
            "pixel coordinates are not accepted"
        )
    if "reference" not in data or "game" not in data:
        raise ComparisonError("landmark JSON requires top-level 'reference' and 'game' entries")

    try:
        ref_points, ref_issues = _extract_side_points(data["reference"], reference_aspect)
        game_points, game_issues = _extract_side_points(data["game"], game_aspect)
    except ValueError as exc:
        raise ComparisonError(f"invalid landmark structure: {exc}") from exc

    def body_span(points: dict[str, list[tuple[float, float] | None]], aspect: float) -> float | None:
        spans = [
            _distance(head, hip, aspect)
            for head, hip in zip(points["head"], points["hip"])
            if head is not None and hip is not None
        ]
        return statistics.median(spans) if spans else None

    ref_span = body_span(ref_points, reference_aspect)
    game_span = body_span(game_points, game_aspect)
    sides = {
        "reference": {
            "aspect_ratio": round(reference_aspect, 9),
            "body_span": round(ref_span, 9) if ref_span is not None else None,
            "issues": ref_issues,
        },
        "game": {
            "aspect_ratio": round(game_aspect, 9),
            "body_span": round(game_span, 9) if game_span is not None else None,
            "issues": game_issues,
        },
    }
    groups: dict[str, Any] = {}
    for group in ("head", "hip", "knee"):
        ref_result = _group_measure(group, ref_points, ref_span, reference_aspect)
        game_result = _group_measure(group, game_points, game_span, game_aspect)
        ratio = None
        ratio_reason = None
        ref_length = ref_result.get("normalized_path_length")
        game_length = game_result.get("normalized_path_length")
        if ref_length is None or game_length is None:
            ratio_reason = "one or both normalized path lengths are unavailable"
        elif ref_length <= 1e-9:
            ratio_reason = "reference normalized displacement is zero"
        else:
            ratio = round(game_length / ref_length, 9)

        if ref_result["status"] == "unavailable" or game_result["status"] == "unavailable":
            status = "unavailable"
        elif ref_result["status"] == "partial" or game_result["status"] == "partial" or ratio is None:
            status = "partial"
        else:
            status = "available"
        groups[group] = {
            "status": status,
            "reference": ref_result,
            "game": game_result,
            "game_to_reference_ratio": ratio,
            "ratio_reason_if_unavailable": ratio_reason,
        }

    any_available = any(group["status"] != "unavailable" for group in groups.values())
    return {
        **base,
        "status": "available" if any_available else "unavailable",
        "phases": [phase.phase_id for phase in PHASES],
        "sides": sides,
        "groups": groups,
        "note": "A displacement ratio compares motion magnitudes; it does not establish pose equivalence or 1:1 matching.",
    }


def frame_count_summary(
    reference_input_count: int,
    reference_clip_count: int,
    game_total_count: int,
    game_window_count: int,
    phase_records: Sequence[dict[str, Any]],
    animation: dict[str, Any],
) -> dict[str, int]:
    return {
        "reference_input_frames": reference_input_count,
        "reference_comparison_frames": reference_clip_count,
        "game_input_frames": game_total_count,
        "game_frames_in_requested_window": game_window_count,
        "key_phase_count": len(phase_records),
        "key_phase_unique_reference_frames": len({item["reference"]["selected_frame"] for item in phase_records}),
        "key_phase_unique_game_frames": len({item["game"]["selected_frame"] for item in phase_records}),
        "animation_sample_count": int(animation["sample_count"]),
        "animation_unique_reference_frames": int(animation["unique_reference_frames"]),
        "animation_unique_game_frames": int(animation["unique_game_frames"]),
    }


def _format_optional(value: Any) -> str:
    return "unavailable" if value is None else f"{value:.6f}"


def render_gallery(
    out_dir: Path,
    args: argparse.Namespace,
    phase_records: Sequence[dict[str, Any]],
    animation: dict[str, Any],
    counts: dict[str, int],
    manifests: dict[str, Any],
    landmark_data: dict[str, Any],
    warnings: Sequence[str],
) -> Path:
    phase_cards: list[str] = []
    for item in phase_records:
        ref = item["reference"]
        game = item["game"]
        phase_cards.append(
            f"""
            <section class="phase">
              <h2>{html.escape(item['label'])} <small>normalized {item['normalized_time']:.3f}</small></h2>
              <p>{html.escape(item['description'])}</p>
              <a href="{html.escape(item['strip'])}"><img src="{html.escape(item['strip'])}" alt="Reference and game frames for {html.escape(item['label'])}"></a>
              <div class="times">
                <div><strong>Reference</strong><br>target {ref['target_source_seconds']:.3f}s · selected {ref['selected_source_seconds']:.3f}s · offset {ref['offset_seconds']:+.3f}s ({ref['offset_frames_at_fps']:+.2f}f)<br><code>{html.escape(ref['selected_frame'])}</code></div>
                <div><strong>Game</strong><br>target {game['target_source_seconds']:.3f}s · selected {game['selected_source_seconds']:.3f}s · offset {game['offset_seconds']:+.3f}s ({game['offset_frames_at_fps']:+.2f}f)<br><code>{html.escape(game['selected_frame'])}</code></div>
              </div>
            </section>
            """
        )

    if landmark_data["status"] == "unavailable":
        landmark_section = (
            f"<p class=\"unavailable\"><strong>Unavailable.</strong> "
            f"{html.escape(landmark_data.get('reason', 'No landmark measurements were supplied.'))}</p>"
        )
    else:
        rows: list[str] = []
        for group, result in landmark_data["groups"].items():
            ref_length = result["reference"].get("normalized_path_length")
            game_length = result["game"].get("normalized_path_length")
            ratio = result.get("game_to_reference_ratio")
            missing = sorted(
                set(result["reference"].get("missing_phases", []))
                | set(result["game"].get("missing_phases", []))
            )
            rows.append(
                "<tr>"
                f"<td>{html.escape(group)}</td>"
                f"<td>{html.escape(result['status'])}</td>"
                f"<td>{_format_optional(ref_length)}</td>"
                f"<td>{_format_optional(game_length)}</td>"
                f"<td>{_format_optional(ratio)}</td>"
                f"<td>{html.escape(', '.join(missing) if missing else 'none')}</td>"
                "</tr>"
            )
        landmark_section = (
            "<p>These are body-scale-normalized displacement ratios from caller-supplied coordinates. "
            "They are not pose-match scores.</p>"
            "<table><thead><tr><th>Joint</th><th>Status</th><th>REF normalized path</th>"
            "<th>GAME normalized path</th><th>GAME / REF ratio</th><th>Missing phases</th></tr></thead>"
            f"<tbody>{''.join(rows)}</tbody></table>"
        )

    warning_html = ""
    if warnings:
        warning_html = "<div class=\"warning\"><strong>Alignment warnings</strong><ul>" + "".join(
            f"<li>{html.escape(warning)}</li>" for warning in warnings
        ) + "</ul></div>"

    page = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>KnockNight · Fight Night visual comparison</title>
  <style>
    :root {{ color-scheme: dark; --ink:#edf3f8; --muted:#aab7c4; --line:#2b3947; --panel:#111922; --gold:#f4c95d; }}
    * {{ box-sizing: border-box; }}
    body {{ margin:0; background:#070b10; color:var(--ink); font:16px/1.55 ui-sans-serif, system-ui, sans-serif; }}
    main {{ max-width:1720px; margin:0 auto; padding:32px 24px 72px; }}
    h1 {{ margin:0 0 8px; font-size:clamp(28px,4vw,48px); letter-spacing:-.025em; }}
    h2 {{ font-size:20px; margin:8px 0; }} h2 small {{ color:var(--muted); font-weight:500; }}
    p {{ margin:8px 0; }}
    a {{ color:#7fd1ff; }}
    code {{ color:#cfe5f3; background:#0a1119; padding:2px 5px; border-radius:4px; }}
    .claim {{ border:1px solid #7c6426; background:#211c0f; color:#f7dfa4; padding:14px 18px; border-radius:10px; margin:18px 0; }}
    .summary {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(160px,1fr)); gap:10px; margin:20px 0; }}
    .metric {{ border:1px solid var(--line); background:var(--panel); border-radius:9px; padding:12px 14px; }}
    .metric strong {{ display:block; font-size:25px; color:var(--gold); }}
    .projection, .phase {{ border-top:1px solid var(--line); padding-top:24px; margin-top:26px; }}
    .phase img, .master img {{ display:block; width:100%; height:auto; border:1px solid var(--line); border-radius:8px; background:#05080b; }}
    .times {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(320px,1fr)); gap:10px; margin-top:10px; }}
    .times > div {{ border:1px solid var(--line); background:var(--panel); border-radius:8px; padding:10px 12px; }}
    .warning {{ border-left:4px solid #eab94d; background:#1b170d; padding:12px 18px; margin:18px 0; }}
    .unavailable {{ border-left:4px solid #6c7a88; background:#121922; padding:12px 18px; }}
    table {{ border-collapse:collapse; width:100%; font-size:14px; }} th,td {{ border:1px solid var(--line); padding:8px 10px; text-align:left; }} th {{ background:#151f2a; }}
    .notes {{ color:var(--muted); font-size:14px; }}
  </style>
</head>
<body><main>
  <h1>KnockNight · visual comparison</h1>
  <p>Reference and game are sampled on one normalized time axis. Each still pair shows the selected source frames and their timing offsets.</p>
  <div class="claim"><strong>Alignment evidence only.</strong> This gallery does not claim an automatic 1:1 or pose match. Matching requires human review against the actual motion, framing, timing, and landmarks.</div>
  {warning_html}
  <h2>Frame counts</h2>
  <div class="summary">
    <div class="metric"><strong>{counts['reference_input_frames']:,}</strong>reference input frames</div>
    <div class="metric"><strong>{counts['reference_comparison_frames']:,}</strong>reference comparison frames</div>
    <div class="metric"><strong>{counts['game_input_frames']:,}</strong>game input frames</div>
    <div class="metric"><strong>{counts['game_frames_in_requested_window']:,}</strong>game frames in window</div>
    <div class="metric"><strong>{counts['key_phase_count']}</strong>key phase pairs</div>
    <div class="metric"><strong>{counts['animation_sample_count']}</strong>GIF samples</div>
  </div>
  <p><a href="comparison.gif">Open the matched-time animated GIF</a> · <a href="manifest.json">timing manifest</a> · <a href="summary.json">frame summary JSON</a> · <a href="summary.txt">summary text</a></p>
  <section class="projection">
    <h2>Matched-time animation</h2>
    <p>{animation['sample_count']} side-by-side samples at {args.fps:g} fps, {animation['frame_duration_ms']} ms per GIF frame.</p>
    <img src="comparison.gif" alt="Animated side-by-side reference and game comparison">
  </section>
  <section class="projection">
    <h2>Six key phases</h2>
    <p>GUARD → ENTRY → PEAK → HOLD → RELEASE → GUARD. Target times are normalized over the reference comparison duration; nearest actual source frames are labeled.</p>
    {''.join(phase_cards)}
  </section>
  <section class="projection master">
    <h2>Key-phase contact sheet</h2>
    <a href="key_phases.png"><img src="key_phases.png" alt="Six vertically stacked reference/game phase pairs"></a>
  </section>
  <section class="projection">
    <h2>Optional landmark displacement</h2>
    {landmark_section}
  </section>
  <section class="projection notes">
    <h2>Transform and timing notes</h2>
    <p>Whole-frame operations only: crop, optional whole-reference mirror, then aspect-preserving scale to fit a panel. The source geometry is never stretched.</p>
    <p>Reference: <code>{html.escape(str(args.reference))}</code>, start {args.ref_start:.3f}s, duration {args.ref_duration:.3f}s, {args.fps:g} fps. Game: <code>{html.escape(str(args.game))}</code>, start {args.game_start:.3f}s.</p>
    <p>Signed offset = selected source time − target source time. Positive values mean the nearest available frame is later. Directory timestamps assume frame index / fps.</p>
  </section>
</main></body></html>
"""
    gallery_path = out_dir / "gallery.html"
    gallery_path.write_text(page, encoding="utf-8")
    return gallery_path


def write_summary(
    out_dir: Path,
    args: argparse.Namespace,
    counts: dict[str, int],
    landmark_data: dict[str, Any],
    warnings: Sequence[str],
    output_files: Sequence[Path],
) -> tuple[Path, Path, dict[str, Any]]:
    summary = {
        "frame_counts": counts,
        "reference": {
            "path": str(args.reference),
            "start_seconds": args.ref_start,
            "duration_seconds": args.ref_duration,
            "fps": args.fps,
        },
        "game": {"path": str(args.game), "start_seconds": args.game_start},
        "key_phases": [
            {"id": phase.phase_id, "label": phase.label, "normalized_time": phase.normalized_time}
            for phase in PHASES
        ],
        "landmark_displacement_status": landmark_data["status"],
        "warnings": list(warnings),
        "outputs": [path.relative_to(out_dir).as_posix() for path in output_files],
        "claim": {
            "automatic_1to1_match": False,
            "pose_match_score": None,
            "statement": "Visual alignment evidence only; human review is required.",
        },
    }
    summary_json = out_dir / "summary.json"
    summary_json.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

    warning_lines = "\n".join(f"  - {warning}" for warning in warnings) if warnings else "  - none"
    output_lines = "\n".join(f"  - {path.relative_to(out_dir).as_posix()}" for path in output_files)
    text = (
        "KnockNight Fight Night visual comparison\n"
        "========================================\n"
        f"Reference: {args.reference}\n"
        f"Game:      {args.game}\n"
        f"Window:    ref {args.ref_start:.3f}s + {args.ref_duration:.3f}s; "
        f"game start {args.game_start:.3f}s; {args.fps:g} fps\n\n"
        "Frame counts\n"
        f"  reference input:                 {counts['reference_input_frames']}\n"
        f"  reference comparison frames:     {counts['reference_comparison_frames']}\n"
        f"  game input:                      {counts['game_input_frames']}\n"
        f"  game frames in requested window: {counts['game_frames_in_requested_window']}\n"
        f"  key phase pairs:                 {counts['key_phase_count']}\n"
        f"  animation samples:               {counts['animation_sample_count']}\n\n"
        f"Landmark displacement status: {landmark_data['status']}\n"
        f"Warnings:\n{warning_lines}\n\n"
        f"Outputs:\n{output_lines}\n\n"
        "Claim: visual alignment evidence only. No automatic 1:1 or pose-match claim.\n"
    )
    summary_txt = out_dir / "summary.txt"
    summary_txt.write_text(text, encoding="utf-8")
    return summary_json, summary_txt, summary


def run(args: argparse.Namespace, parser: argparse.ArgumentParser) -> Path:
    global PHASES
    validate_args(parser, args)
    if args.phase_times:
        try:
            times = [float(v) for v in args.phase_times.split(",")]
        except ValueError:
            parser.error("--phase-times must contain six comma-separated numbers")
        if len(times) != len(PHASES) or any(not 0 <= t <= 1 for t in times) or any(b <= a for a, b in zip(times, times[1:])):
            parser.error("--phase-times must contain six strictly increasing values in [0,1]")
        PHASES = tuple(Phase(p.phase_id, p.label, t, p.description) for p, t in zip(PHASES, times))
    reference = args.reference.resolve()
    game_dir = args.game.resolve()
    out_dir = args.out.resolve()
    if not reference.exists():
        raise ComparisonError(f"reference does not exist: {reference}")
    if not game_dir.is_dir():
        raise ComparisonError(f"game input must be a frame directory: {game_dir}")
    if reference.is_file() and reference.suffix.casefold() not in VIDEO_EXTENSIONS:
        raise ComparisonError(
            f"reference file is not a supported video ({', '.join(sorted(VIDEO_EXTENSIONS))}): {reference}"
        )

    prepare_output_dir(out_dir, args.overwrite)
    warnings: list[str] = []
    extraction_command: list[str] | None = None

    if reference.is_dir():
        reference_input_paths = collect_frame_directory(reference)
        reference_frames = frames_with_times(reference_input_paths, 0.0, args.fps)
        reference_kind = "frame directory"
        reference_origin = 0.0
    else:
        reference_input_paths, extraction_command = extract_reference_video(
            reference,
            out_dir / "reference_frames",
            args.ref_start,
            args.ref_duration,
            args.fps,
        )
        reference_frames = frames_with_times(reference_input_paths, args.ref_start, args.fps)
        reference_kind = "video"
        reference_origin = args.ref_start

    expected_reference_frames = max(1, int(round(args.ref_duration * args.fps)))
    if len(reference_frames) < expected_reference_frames:
        warnings.append(
            f"Reference produced {len(reference_frames)} comparison frames; "
            f"{expected_reference_frames} were expected for {args.ref_duration:g}s at {args.fps:g} fps. "
            "Near-end phase samples may clamp to the last available frame."
        )

    game_paths = collect_frame_directory(game_dir)
    game_manifest = game_dir / "sequence_manifest.json"
    if game_manifest.is_file():
        captures = json.loads(game_manifest.read_text(encoding="utf-8-sig"))
        game_frames = [SourceFrame(index=int(row["index"]), path=Path(row["image"]), seconds=float(row["time"]))
                       for row in captures["frames"]]
    else:
        game_frames = frames_with_times(game_paths, 0.0, args.fps)
    window_end = args.game_start + args.ref_duration
    game_window_count = sum(
        1 for frame in game_frames if args.game_start - 1.0 / (2.0 * args.fps) <= frame.seconds <= window_end
    )
    if game_frames[0].seconds > args.game_start + 1.0 / (2.0 * args.fps):
        warnings.append("The first game frame begins after --game-start.")
    if game_frames[-1].seconds + 1.0 / (2.0 * args.fps) < window_end:
        warnings.append(
            f"Game coverage ends at approximately {game_frames[-1].seconds:.3f}s, before the requested "
            f"{window_end:.3f}s endpoint. Late samples clamp to the final available game frame."
        )

    ref_phases = key_phase_selections(reference_frames, args.ref_start if reference_kind == "video" else 0.0, args.ref_duration)
    game_phases = key_phase_selections(game_frames, args.game_start, args.ref_duration)
    phase_records, phase_files, prepared_sizes = render_phase_strips(
        out_dir,
        ref_phases,
        game_phases,
        args.ref_crop,
        args.game_crop,
        args.mirror_ref,
        args.fps,
        warnings,
    )

    ref_samples = animation_selections(
        reference_frames,
        args.ref_start if reference_kind == "video" else 0.0,
        args.ref_duration,
        args.fps,
    )
    game_samples = animation_selections(game_frames, args.game_start, args.ref_duration, args.fps)
    animation, gif_path = render_animation(
        out_dir,
        ref_samples,
        game_samples,
        args.game_start,
        args.ref_crop,
        args.game_crop,
        args.mirror_ref,
        args.ref_duration,
        args.fps,
    )

    reference_aspect = prepared_sizes["reference"][0] / prepared_sizes["reference"][1]
    game_aspect = prepared_sizes["game"][0] / prepared_sizes["game"][1]
    landmark_data = landmark_measurements(args.landmarks, reference_aspect, game_aspect)
    landmark_path = out_dir / "landmark_measurements.json"
    landmark_path.write_text(json.dumps(landmark_data, indent=2) + "\n", encoding="utf-8")

    counts = frame_count_summary(
        len(reference_input_paths),
        len(reference_frames),
        len(game_frames),
        game_window_count,
        phase_records,
        animation,
    )
    gallery_path = render_gallery(
        out_dir,
        args,
        phase_records,
        animation,
        counts,
        {},
        landmark_data,
        warnings,
    )

    manifest = {
        "schema_version": 1,
        "tool": "tools/compare_fn_reference.py",
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "purpose": (
            "Visual comparison and transparent phase alignment for separately built "
            "KnockNight Fight Night reference and game captures."
        ),
        "claim": {
            "automatic_1to1_match": False,
            "pose_match_score": None,
            "statement": "No automatic 1:1 or pose-match claim is made.",
        },
        "inputs": {
            "reference": {
                "path": str(reference),
                "kind": reference_kind,
                "start_seconds": args.ref_start,
                "duration_seconds": args.ref_duration,
                "fps": args.fps,
                "frame_time_origin_seconds": reference_origin,
                "timestamp_rule": (
                    "ffmpeg fps-filter output index / fps plus --ref-start"
                    if reference_kind == "video"
                    else "source directory index / --fps"
                ),
            },
            "game": {
                "path": str(game_dir),
                "start_seconds": args.game_start,
                "timestamp_rule": "source directory index / --fps",
            },
            "landmarks": str(args.landmarks.resolve()) if args.landmarks else None,
        },
        "timing": {
            "normalized_phase_targets": [
                {
                    "phase_id": phase.phase_id,
                    "label": phase.label,
                    "normalized_time": phase.normalized_time,
                }
                for phase in PHASES
            ],
            "reference_target_formula": "ref_start + normalized_time * ref_duration",
            "game_target_formula": "game_start + normalized_time * ref_duration",
            "offset_definition": "selected_source_seconds - target_source_seconds",
            "offset_sign": "positive means the selected frame is later than the target",
            "timing_quantization_note": (
                "The manifest records nearest-frame selection and signed offsets. "
                "Video extraction cadence is also subject to ffmpeg fps-filter frame quantization."
            ),
        },
        "whole_frame_transforms": {
            "reference_crop_source_pixels": list(args.ref_crop) if args.ref_crop else None,
            "game_crop_source_pixels": list(args.game_crop) if args.game_crop else None,
            "mirror_whole_reference_after_crop": args.mirror_ref,
            "display_scale": "aspect-preserving contain fit; never stretch",
            "other_pose_edits": [],
        },
        "frame_counts": counts,
        "phase_alignment": phase_records,
        "animation": {key: value for key, value in animation.items() if key != "samples"},
        "animation_samples": animation["samples"],
        "landmark_measurements": landmark_data,
        "warnings": warnings,
        "extraction_command": extraction_command,
        "outputs": {
            "gallery": gallery_path.name,
            "comparison_gif": gif_path.name,
            "key_phase_contact_sheet": "key_phases.png",
            "phase_strips": [path.relative_to(out_dir).as_posix() for path in phase_files if path.parent.name == "strips"],
            "landmark_measurements": landmark_path.name,
            "summary_json": "summary.json",
            "summary_text": "summary.txt",
        },
    }
    manifest_path = out_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    output_files = [
        gallery_path,
        gif_path,
        out_dir / "key_phases.png",
        *[path for path in phase_files if path.parent.name == "strips"],
        manifest_path,
        landmark_path,
    ]
    summary_json, summary_txt, _ = write_summary(
        out_dir, args, counts, landmark_data, warnings, output_files
    )
    print(summary_txt.read_text(encoding="utf-8"), end="")
    print(f"\nGallery: {gallery_path}")
    print(f"Manifest: {manifest_path}")
    print(f"Summary: {summary_json}")
    return gallery_path


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        run(args, parser)
    except ComparisonError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
