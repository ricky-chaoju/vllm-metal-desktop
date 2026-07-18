# Progress = truth on disk. The Hub API resolves every file's exact size and
# blob name once up front; a timer thread then stats the cache twice a second:
# completed blobs count in full, in-flight *.incomplete files at their current
# size (covers both the pre-1.18 `<etag>.incomplete` and the 1.18+
# `<etag>.<uuid>.incomplete` naming). Already-cached files are therefore
# counted from the very first tick, and the emitted counter is monotonic —
# independent of huggingface_hub's tqdm internals, which changed incompatibly
# across 0.x / 1.18 / 1.23. Speed is NOT computed here; the app derives it
# from these samples with a sliding window.
import json, sys, threading
from pathlib import Path

from huggingface_hub import HfApi, constants, snapshot_download


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def lfs_field(lfs, name):
    if lfs is None:
        return None
    if isinstance(lfs, dict):
        return lfs.get(name)
    return getattr(lfs, name, None)


def resolve_files(repo_id, revision):
    """(commit_sha, total_bytes, [(relpath, size, blob_name)]) from one API call.

    blob_name is the file's name under blobs/: the LFS sha256 for large files,
    the git blob id for small ones — exactly how huggingface_hub names them.
    """
    info = HfApi().model_info(repo_id, revision=revision, files_metadata=True)
    files = []
    total = 0
    for sibling in info.siblings or []:
        size = sibling.size or lfs_field(sibling.lfs, "size") or 0
        blob_name = lfs_field(sibling.lfs, "sha256") or getattr(sibling, "blob_id", None)
        total += size
        files.append((sibling.rfilename, size, blob_name))
    return info.sha, total, files


def bytes_on_disk(repo_dir, commit, files):
    """Real cumulative bytes for this snapshot: full size for completed files,
    current on-disk size for in-flight ones."""
    blobs = repo_dir / "blobs"
    snapshot = repo_dir / "snapshots" / (commit or "")
    downloaded = 0
    for relpath, size, blob_name in files:
        if blob_name:
            if (blobs / blob_name).exists():
                downloaded += size
                continue
            partial = 0
            for candidate in blobs.glob(f"{blob_name}*.incomplete"):
                try:
                    partial = max(partial, candidate.stat().st_size)
                except OSError:
                    pass
            downloaded += min(partial, size)
        elif commit and (snapshot / relpath).exists():
            downloaded += size
    return downloaded


def progress_loop(stop, repo_dir, commit, total, files):
    while True:
        emit({"type": "progress",
              "downloaded": bytes_on_disk(repo_dir, commit, files),
              "total": total})
        if stop.wait(0.5):
            return


def main():
    if len(sys.argv) < 2:
        emit({"type": "error", "message": "missing model id"})
        sys.exit(2)
    repo_id = sys.argv[1]
    revision = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else None

    repo_dir = Path(constants.HF_HUB_CACHE) / ("models--" + repo_id.replace("/", "--"))

    # Metadata failure isn't fatal — snapshot_download may still succeed from
    # cache; the bar just runs indeterminate (total 0).
    try:
        commit, total, files = resolve_files(repo_id, revision)
    except Exception:
        commit, total, files = None, 0, []

    stop = threading.Event()
    if files:
        thread = threading.Thread(
            target=progress_loop, args=(stop, repo_dir, commit, total, files), daemon=True
        )
        thread.start()

    try:
        path = snapshot_download(repo_id, revision=revision)
    except Exception as exc:
        stop.set()
        emit({"type": "error", "message": str(exc)})
        sys.exit(1)
    stop.set()
    if total:
        emit({"type": "progress", "downloaded": total, "total": total})
    emit({"type": "done", "path": path})


main()
