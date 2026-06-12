#!/usr/bin/env python3
"""Migrate touch-code on-disk state to Codans.

The 0.4.5 rename (touch-code -> Codans) deliberately performed no migration:
config moved from ~/.config/touch-code to ~/.config/codans and managed
worktrees from ~/.touch-code/repos to ~/.codans/repos, leaving old state
behind. Moving directories by hand breaks git's worktree metadata in both
directions (git stores absolute paths):

  * the main repo's .git/worktrees/<name>/gitdir still points at the old
    ~/.touch-code path, so `git worktree list` reports the live worktree as
    "prunable" (and `git worktree prune` would sever it — do NOT prune first);
  * each worktree's .git file points back at the old main-repo path, which
    may itself have been renamed;
  * submodule .git files inside a worktree embed the old main-repo path.

This script repairs all of it, driven by the Codans catalog:

  1. copy ~/.config/touch-code -> ~/.config/codans when the latter is absent;
  2. move worktree dirs from ~/.touch-code/repos into ~/.codans/repos;
  3. rewrite catalog.json worktree paths to the new prefix and dedupe rows
     (a timestamped backup is written first);
  4. fix stale .git/worktrees/<name> registrations whose worktree moved
     (metadata preserved), and recreate registrations that were already
     pruned (branch taken from the catalog row, index rebuilt via git reset);
  5. repoint worktree submodule gitdirs, cloning module stores from the main
     checkout when the originals were lost to a prune.

Dry-run by default; pass --apply to mutate. Quit the Codans app first — it
rewrites catalog.json on focus/quit and will clobber the edits.

Not covered: ~/Library/Caches/touch-code (zmx daemon sockets — stale after
any reboot, safe to delete) and the old `tc` CLI symlink.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time

OLD_STATE = ".touch-code"
NEW_STATE = ".codans"
OLD_CONFIG = "touch-code"
NEW_CONFIG = "codans"


def sh(args, cwd=None):
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True)


class Migrator:
    def __init__(self, home, apply_changes, unarchive):
        # Keep the path as given — realpath would break prefix matching when
        # stored paths and the resolved home disagree (e.g. /tmp vs /private/tmp).
        self.home = home.rstrip(os.sep)
        self.apply = apply_changes
        self.unarchive = unarchive
        self.old_repos = os.path.join(self.home, OLD_STATE, "repos")
        self.new_repos = os.path.join(self.home, NEW_STATE, "repos")
        # git records realpath'd locations; capture the resolved alias while the
        # old root still exists so both spellings map (e.g. /tmp vs /private/tmp).
        self.old_prefixes = [self.old_repos]
        resolved = os.path.realpath(self.old_repos)
        if resolved != self.old_repos:
            self.old_prefixes.append(resolved)
        self.cfg_old = os.path.join(self.home, ".config", OLD_CONFIG)
        self.cfg_new = os.path.join(self.home, ".config", NEW_CONFIG)
        self.warnings = []
        self.repaired = []

    # ---- plumbing ----------------------------------------------------------

    def do(self, desc, fn):
        tag = "APPLY" if self.apply else "PLAN "
        print(f"[{tag}] {desc}")
        if self.apply:
            fn()

    def warn(self, msg):
        self.warnings.append(msg)
        print(f"[WARN ] {msg}")

    def map_path(self, path):
        """Rewrite an old-prefix path to the new managed-repos root."""
        for prefix in self.old_prefixes:
            if path.startswith(prefix + os.sep):
                return self.new_repos + path[len(prefix):]
        return path

    def reverse_map(self, path):
        """New-prefix path back to its pre-move location (dry-run preview)."""
        if path.startswith(self.new_repos + os.sep):
            return self.old_repos + path[len(self.new_repos):]
        return path

    def locate(self, path):
        """Where the directory actually is right now. During a dry-run the
        repos move hasn't happened, so a new-prefix path may still live at the
        old location; return the existing spelling (or None)."""
        if os.path.isdir(path):
            return path
        if not self.apply:
            old = self.reverse_map(path)
            if os.path.isdir(old):
                return old
        return None

    # ---- step 1: config dir ------------------------------------------------

    def migrate_config(self):
        if os.path.isdir(self.cfg_new):
            return
        if not os.path.isdir(self.cfg_old):
            return
        self.do(
            f"copy config {self.cfg_old} -> {self.cfg_new}",
            lambda: shutil.copytree(self.cfg_old, self.cfg_new, symlinks=True),
        )

    # ---- step 2: managed worktree storage -----------------------------------

    def migrate_repos(self):
        if not os.path.isdir(self.old_repos):
            return
        os.makedirs(self.new_repos, exist_ok=True) if self.apply else None
        for repo in sorted(os.listdir(self.old_repos)):
            src = os.path.join(self.old_repos, repo)
            if not os.path.isdir(src):
                continue
            dst = os.path.join(self.new_repos, repo)
            if not os.path.isdir(dst):
                self.do(f"move {src} -> {dst}", lambda s=src, d=dst: shutil.move(s, d))
            else:
                self.merge_repo_dir(src, dst)

    def merge_repo_dir(self, src, dst):
        """Both old and new repo folders exist: move individual worktree roots."""
        for root, dirs, files in os.walk(src):
            if ".git" in files or ".git" in dirs:
                rel = os.path.relpath(root, src)
                target = os.path.join(dst, rel)
                if os.path.isdir(target):
                    self.warn(f"both old and new exist, skipped: {root} vs {target}")
                else:
                    self.do(
                        f"move {root} -> {target}",
                        lambda r=root, t=target: (
                            os.makedirs(os.path.dirname(t), exist_ok=True),
                            shutil.move(r, t),
                        ),
                    )
                dirs[:] = []  # don't descend into a worktree

    # ---- step 3: catalog ----------------------------------------------------

    def load_catalog(self):
        path = os.path.join(self.cfg_new, "catalog.json")
        if not os.path.isfile(path):
            # Dry-run before the config copy has happened: read the old file.
            old = os.path.join(self.cfg_old, "catalog.json")
            if not self.apply and os.path.isfile(old):
                path = old
            else:
                print(f"[INFO ] no catalog at {path}; skipping catalog + repair steps")
                return None, None
        with open(path) as f:
            return path, json.load(f)

    def fix_catalog(self, path, catalog):
        rewritten = deduped = unarchived = 0
        for project in catalog.get("projects", []):
            seen, kept = set(), []
            for row in project.get("worktrees", []):
                new_path = self.map_path(row.get("path", ""))
                if new_path != row.get("path"):
                    row["path"] = new_path
                    rewritten += 1
                if row["path"] in seen:
                    deduped += 1
                    continue
                seen.add(row["path"])
                if (
                    self.unarchive
                    and row.get("archived")
                    and os.path.isdir(row["path"])
                ):
                    row["archived"] = False
                    row.pop("archivedAt", None)
                    unarchived += 1
                kept.append(row)
            project["worktrees"] = kept
        if rewritten or deduped or unarchived:
            stamp = time.strftime("%Y%m%d-%H%M%S")

            def save():
                shutil.copy2(path, f"{path}.pre-migrate-{stamp}")
                target = os.path.join(self.cfg_new, "catalog.json")
                with open(target, "w") as f:
                    json.dump(catalog, f, sort_keys=True, separators=(",", ":"))
                    f.flush()
                    os.fsync(f.fileno())

            self.do(
                f"catalog: rewrite {rewritten} path(s), drop {deduped} duplicate(s), "
                f"unarchive {unarchived} row(s) (backup: catalog.json.pre-migrate-{stamp})",
                save,
            )
        return catalog

    # ---- step 4: git worktree registrations ---------------------------------

    def repair_registrations(self, catalog, extra_repos):
        roots = [
            p.get("gitRoot")
            for p in (catalog or {}).get("projects", [])
            if p.get("gitRoot")
        ] + list(extra_repos)
        rows_by_root = {}
        for p in (catalog or {}).get("projects", []):
            if p.get("gitRoot"):
                rows_by_root[p["gitRoot"]] = p.get("worktrees", [])
        for root in dict.fromkeys(roots):  # de-dupe, keep order
            if not os.path.isdir(os.path.join(root, ".git")):
                self.warn(f"not a git repo, skipped: {root}")
                continue
            self.fix_stale_admins(root)
            for row in rows_by_root.get(root, []):
                self.ensure_registration(root, row)

    def fix_stale_admins(self, root):
        """Registration exists but its gitdir points at the moved (old) path."""
        admins = os.path.join(root, ".git", "worktrees")
        if not os.path.isdir(admins):
            return
        for name in sorted(os.listdir(admins)):
            gitdir_file = os.path.join(admins, name, "gitdir")
            if not os.path.isfile(gitdir_file):
                continue
            target = open(gitdir_file).read().strip()  # "<wt>/.git"
            if os.path.exists(target):
                continue
            moved = self.map_path(os.path.dirname(target))
            if self.locate(moved):
                self.relink(root, name, moved)
            else:
                self.warn(
                    f"{root}: registration '{name}' points at missing "
                    f"{os.path.dirname(target)} and no moved copy exists; left as-is"
                )

    def ensure_registration(self, root, row):
        """Catalog row -> healthy registration, recreating a pruned one if needed."""
        wt = row.get("path", "")
        if not wt or os.path.realpath(wt) == os.path.realpath(root):
            return  # main checkout
        actual = self.locate(wt)  # pre-move location during a dry-run
        if not actual:
            return  # genuinely gone; reconcile will archive the row
        dotgit = os.path.join(actual, ".git")
        if os.path.isdir(dotgit):
            return  # full clone, not a linked worktree
        if not os.path.isfile(dotgit):
            self.warn(f"{wt}: no .git file; cannot repair")
            return
        pointer = open(dotgit).read().strip().removeprefix("gitdir:").strip()
        name = os.path.basename(pointer)
        admin = os.path.join(root, ".git", "worktrees", name)
        if os.path.isdir(admin):
            self.relink(root, name, wt)
            return
        branch = row.get("branch")
        if not branch:
            self.warn(f"{wt}: registration pruned and catalog row has no branch; skipped")
            return
        if sh(["git", "show-ref", "--verify", f"refs/heads/{branch}"], cwd=root).returncode != 0:
            self.warn(f"{wt}: branch '{branch}' not found in {root}; skipped")
            return

        def recreate():
            os.makedirs(admin, exist_ok=True)
            with open(os.path.join(admin, "gitdir"), "w") as f:
                f.write(f"{wt}/.git\n")
            with open(os.path.join(admin, "HEAD"), "w") as f:
                f.write(f"ref: refs/heads/{branch}\n")
            with open(os.path.join(admin, "commondir"), "w") as f:
                f.write("../..\n")
            with open(dotgit, "w") as f:
                f.write(f"gitdir: {admin}\n")
            # The pruned registration took the index with it; rebuild from HEAD
            # (mixed reset never touches working-tree files).
            r = sh(["git", "reset", "-q"], cwd=wt)
            if r.returncode != 0:
                self.warn(f"{wt}: git reset failed: {r.stderr.strip()}")

        self.do(f"recreate pruned registration {root} <- {wt} [{branch}]", recreate)
        self.repaired.append((root, name, wt))

    def relink(self, root, name, wt):
        """Point an existing registration and the worktree .git file at each other."""
        admin = os.path.join(root, ".git", "worktrees", name)
        dotgit = os.path.join(wt, ".git")
        want_gitdir = f"{wt}/.git\n"
        want_pointer = f"gitdir: {admin}\n"
        gitdir_file = os.path.join(admin, "gitdir")
        current_gitdir = open(gitdir_file).read() if os.path.isfile(gitdir_file) else ""
        current_pointer = open(dotgit).read() if os.path.isfile(dotgit) else ""
        if current_gitdir == want_gitdir and current_pointer == want_pointer:
            return

        def fix():
            with open(gitdir_file, "w") as f:
                f.write(want_gitdir)
            with open(dotgit, "w") as f:
                f.write(want_pointer)

        self.do(f"relink registration {root} <-> {wt}", fix)
        self.repaired.append((root, name, wt))

    # ---- step 5: submodules --------------------------------------------------

    def repair_submodules(self):
        for root, name, wt in self.repaired:
            modules_file = os.path.join(wt, ".gitmodules")
            if not os.path.isfile(modules_file):
                continue
            r = sh(["git", "config", "-f", modules_file, "--get-regexp", r"submodule\..*\.path"])
            for line in r.stdout.splitlines():
                sub_rel = line.split(" ", 1)[1].strip()
                self.repair_one_submodule(root, name, wt, sub_rel)

    def repair_one_submodule(self, root, name, wt, sub_rel):
        sub_dir = os.path.join(wt, sub_rel)
        sub_dotgit = os.path.join(sub_dir, ".git")
        if not os.path.isfile(sub_dotgit):
            return  # never initialized here
        pointer = open(sub_dotgit).read().strip().removeprefix("gitdir:").strip()
        resolved = os.path.normpath(os.path.join(sub_dir, pointer)) if not os.path.isabs(pointer) else pointer
        if os.path.isdir(resolved):
            return  # healthy
        module = os.path.join(root, ".git", "worktrees", name, "modules", sub_rel)
        if not os.path.isdir(module):
            source = os.path.join(root, ".git", "modules", sub_rel)
            if not os.path.isdir(source):
                self.warn(
                    f"{sub_dir}: module store missing and main checkout has no "
                    f"{source}; run `git submodule update --init {sub_rel}` later"
                )
                return

            def clone():
                os.makedirs(os.path.dirname(module), exist_ok=True)
                # APFS clonefile keeps this near-free; fall back to a real copy.
                if subprocess.run(["cp", "-Rc", source, module], capture_output=True).returncode != 0:
                    shutil.copytree(source, module)

            self.do(f"clone module store {source} -> {module}", clone)

        def repoint():
            with open(sub_dotgit, "w") as f:
                f.write(f"gitdir: {module}\n")
            # --file edits the config directly; `--git-dir config` would chdir
            # through the stale core.worktree and die.
            sh(["git", "config", "--file", os.path.join(module, "config"),
                "core.worktree", sub_dir])

        self.do(f"repoint submodule {sub_dir} -> {module}", repoint)

    # ---- step 6: verify -------------------------------------------------------

    def verify(self):
        if not self.apply:
            return  # nothing was mutated; status would report pre-repair state
        ok = bad = 0
        for _, _, wt in self.repaired:
            if sh(["git", "status", "--porcelain"], cwd=wt).returncode == 0:
                ok += 1
            else:
                bad += 1
                self.warn(f"verify failed: git status broken in {wt}")
        if self.repaired:
            print(f"[INFO ] verified {ok}/{ok + bad} repaired worktrees healthy")


def app_running():
    r = sh(["pgrep", "-f", "MacOS/(Codans|touch-code)"])
    if r.returncode != 0:
        # pgrep -f with alternation needs -E semantics on some systems; retry plainly.
        r = sh(["pgrep", "-f", "MacOS/Codans"])
    return r.returncode == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--apply", action="store_true", help="perform changes (default: dry-run)")
    parser.add_argument("--unarchive", action="store_true",
                        help="also un-archive catalog rows whose directory exists on disk")
    parser.add_argument("--repo", action="append", default=[], metavar="PATH",
                        help="extra main-repo path to scan (repeatable; catalog projects are scanned automatically)")
    parser.add_argument("--home", default=os.path.expanduser("~"), help=argparse.SUPPRESS)
    args = parser.parse_args()

    real_home = args.home == os.path.expanduser("~")
    if args.apply and real_home and app_running():
        sys.exit("Codans (or touch-code) is running — quit it first; it rewrites catalog.json on focus/quit.")

    m = Migrator(args.home, args.apply, args.unarchive)
    m.migrate_config()
    m.migrate_repos()
    path, catalog = m.load_catalog()
    if catalog is not None:
        catalog = m.fix_catalog(path, catalog)
    m.repair_registrations(catalog, args.repo)
    m.repair_submodules()
    m.verify()

    print()
    if not args.apply:
        print("Dry-run complete. Re-run with --apply to perform the changes above.")
    else:
        print("Done. Launch Codans — worktrees are re-discovered on startup.")
        print("Worktrees whose submodule store was cloned may need `git submodule update`.")
    if m.warnings:
        print(f"{len(m.warnings)} warning(s) above need a manual look.")


if __name__ == "__main__":
    main()
