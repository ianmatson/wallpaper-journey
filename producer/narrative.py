#!/usr/bin/env python3
"""Private story transactions. Production entrypoint: wallpaper-producer only.

The wrapper holds the command lock. Immutable, content-addressed revisions hold
complete snapshots; CURRENT is the sole commit point. Pending work survives a
crash, including a crash between remote publication and the local commit.
"""

import copy
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile


class StoryError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise StoryError(message)


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def text(value, label, limit=12000):
    require(isinstance(value, str) and value.strip() and len(value) <= limit,
            f"invalid {label}")


def safe(path):
    require(not any(p.is_symlink() for p in (path, *path.parents)),
            "story paths must not contain symlinks")
    return path


def read(path):
    safe(path)
    return json.loads(path.read_text())


def write(path, data, immutable=False, mode=0o600):
    """Durable file replacement, or immutable acceptance with identical retries."""
    safe(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if immutable and path.exists():
        require(path.read_bytes() == data, "immutable story record differs")
        return
    fd, tmp = tempfile.mkstemp(prefix=".story-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if immutable:
            os.link(tmp, path)
            os.unlink(tmp)
        else:
            os.replace(tmp, path)
        sync_dir(path.parent)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def validate_state(state):
    require(isinstance(state, dict) and set(state) == {"characters", "facts", "threads"},
            "state requires characters, facts, and threads")
    for collection, records in state.items():
        require(isinstance(records, dict), f"invalid {collection}")
        for key, record in records.items():
            require(re.fullmatch(r"[a-z][a-z0-9_-]{0,79}", key) is not None,
                    "invalid stable story ID")
            require(isinstance(record, dict), "invalid story record")
            text(record.get("description"), "record description")
            text(record.get("status"), "record status", 100)
            if collection == "characters":
                for field in ("name", "visual", "desire", "belief"):
                    text(record.get(field), f"character {field}")
                require(isinstance(record.get("relationships"), dict), "relationships must be an object")
                require(set(record["relationships"]) <= set(state["characters"]),
                        "relationship refers to an unknown character")
                require(isinstance(record.get("name_revealed"), bool), "name_revealed must be boolean")
            if collection == "facts":
                require(isinstance(record.get("audience_knows"), bool), "audience_knows must be boolean")
                require(isinstance(record.get("known_by"), list) and
                        set(record["known_by"]) <= set(state["characters"]),
                        "fact knowledge refers to an unknown character")


def validate_plan(plan, completed=()):
    require(isinstance(plan, dict), "plan must be an object")
    for field in ("season", "ending", "theme", "character_destinations"):
        text(plan.get(field), f"plan {field}")
    require(isinstance(plan.get("arcs"), dict) and plan["arcs"], "plan requires arcs")
    for arc in plan["arcs"].values():
        for field in ("objective", "conflict", "resolution"):
            text(arc.get(field), f"arc {field}")
    beats = plan.get("beats")
    require(isinstance(beats, dict) and beats, "plan requires beats")
    require(set(completed) <= set(beats), "completed beats cannot be removed")
    for key, beat in beats.items():
        require(beat.get("arc") in plan["arcs"], "beat refers to an unknown arc")
        text(beat.get("purpose"), "beat purpose")
        require(isinstance(beat.get("requires"), list) and set(beat["requires"]) <= set(beats),
                "beat prerequisite is missing")
    def visit(key, ancestors):
        require(key not in ancestors, "cyclic beat prerequisites")
        for parent in beats[key]["requires"]:
            visit(parent, ancestors | {key})
    for key in beats:
        visit(key, set())
    promises = plan.get("promises")
    require(isinstance(promises, dict), "plan requires a promises object")
    for promise in promises.values():
        text(promise.get("setup"), "promise setup")
        text(promise.get("payoff"), "promise payoff")
        require(promise.get("target_beat") in beats, "promise payoff beat is missing")
    episodes = plan.get("episodes")
    require(isinstance(episodes, list) and episodes, "plan requires detailed upcoming episodes")
    numbers = []
    for episode in episodes:
        number = episode.get("number")
        require(type(number) is int and number > 0, "invalid planned episode number")
        numbers.append(number)
        require(episode.get("beat") in beats, "episode beat is missing")
        for field in ("purpose", "visible_action"):
            text(episode.get(field), f"episode {field}")
        require(isinstance(episode.get("completes_beat"), bool), "completes_beat must be boolean")
        for field in ("plants", "pays_off"):
            require(isinstance(episode.get(field), list) and set(episode[field]) <= set(promises),
                    "episode refers to an unknown promise")
        for key in episode["pays_off"]:
            require(promises[key]["target_beat"] == episode["beat"], "scheduled payoff has the wrong destination")
    require(numbers == sorted(set(numbers)), "planned episode numbers must be unique and ordered")
    arcs, _ = planning_calendar(plan)
    if arcs:
        for episode in episodes:
            arc = next((a for a in arcs if a["first"] <= episode["number"] <= a["last"]), None)
            require(arc is not None and beats[episode["beat"]]["arc"] == arc["id"],
                    "detailed episode disagrees with the ordered arc schedule")


def planning_calendar(plan):
    """Derive episode boundaries from explicit order, never JSON object order."""
    if "seasons" not in plan:
        return [], []  # Older immutable revisions remain readable.
    require(isinstance(plan["seasons"], list) and plan["seasons"], "seasons must be an ordered list")
    arcs, seasons, seen_arcs, seen_seasons, first = [], [], set(), set(), 1
    for item in plan["seasons"]:
        key = item.get("id")
        require(isinstance(key, str) and re.fullmatch(r"[a-z][a-z0-9_-]{0,79}", key), "invalid season ID")
        require(key not in seen_seasons, "duplicate season ID")
        seen_seasons.add(key)
        for field in ("title", "theme", "ending", "character_destinations", "transition"):
            text(item.get(field), f"season {field}")
        require(isinstance(item.get("arcs"), list) and item["arcs"], "season requires ordered arcs")
        start = first
        for arc in item["arcs"]:
            arc_id, count = arc.get("id"), arc.get("episodes")
            require(arc_id in plan["arcs"] and arc_id not in seen_arcs, "unknown or repeated scheduled arc")
            require(type(count) is int and count > 0, "arc episode target must be positive")
            seen_arcs.add(arc_id)
            arcs.append({"id": arc_id, "season": key, "first": first, "last": first + count - 1})
            first += count
        seasons.append({"id": key, "first": start, "last": first - 1, "outline": item})
    require(seen_arcs == set(plan["arcs"]), "every arc must appear once in the season schedule")
    return arcs, seasons


class Story:
    def __init__(self):
        workspace = Path(os.environ["AI_WALLPAPERS_WORKSPACE_ROOT"])
        self.private = Path(os.environ.get("AI_WALLPAPERS_PRIVATE_ROOT", workspace / "story/private"))
        self.root = safe(self.private / "narrative")
        self.inputs = Path(os.environ.get("AI_WALLPAPERS_INPUT_ROOT", workspace / "tmp")).resolve()
        self.date = os.environ["AI_WALLPAPERS_RUN_DATE"]
        dt.date.fromisoformat(self.date)
        self.tag = "wall-" + self.date
        self.run = os.environ.get("AI_WALLPAPERS_RUN_ID", "")
        self.staging = Path(os.environ.get("AI_WALLPAPERS_STAGING_ROOT", workspace / "story/staging")) / self.tag
        self.native = Path(os.environ.get("AI_WALLPAPERS_NATIVE_ROOT", workspace / "story/native")) / self.tag
        self.current = self.root / "CURRENT"
        self.pending_path = self.root / "pending.json"
        self.control = Path(os.environ.get("AI_WALLPAPERS_CONTROL_DIR", workspace / "control/producer"))

    def input(self, filename):
        path = safe(Path(filename))
        require(path.is_file() and path.resolve().is_relative_to(self.inputs),
                "story input must be a file under the configured input root")
        require(path.stat().st_size <= 2_000_000, "story input exceeds 2 MB")
        return read(path)

    def revision(self, revision):
        require(re.fullmatch(r"[0-9a-f]{64}", revision) is not None, "invalid story revision")
        path = safe(self.root / "revisions" / (revision + ".json"))
        data = path.read_bytes()
        require(digest(data) == revision, "story revision digest mismatch")
        return json.loads(data)

    def head(self):
        require(self.current.exists(), "story state is not initialized")
        revision = safe(self.current).read_text().strip()
        return revision, self.revision(revision)

    def save_revision(self, snapshot):
        data = encoded(snapshot)
        revision = digest(data)
        write(self.root / "revisions" / (revision + ".json"), data, immutable=True)
        return revision

    def point(self, revision):
        write(self.current, (revision + "\n").encode())

    def pending(self):
        return read(self.pending_path) if self.pending_path.exists() else None

    def enabled(self):
        if not self.current.exists():
            return False
        return self.date > self.head()[1]["baseline_date"]

    def guard(self):
        if self.current.exists():
            for lease in self.open_runs():
                require(lease["date"] == self.date,
                        f"unfinished producer run belongs to {lease['date']}; resume that date first")
        pending = self.pending()
        if pending:
            require(pending["date"] == self.date,
                    f"unfinished story episode belongs to {pending['date']}; resume that date first")
            if self.run:
                require(pending["run"] == self.run, "pending episode belongs to another run")

    def open_runs(self):
        return [{"date": p.name.removeprefix("wallpaper-producer-").removesuffix(".lease"),
                 "run": safe(p).read_text().strip()}
                for p in sorted(safe(self.control).glob("wallpaper-producer-*.lease"))]

    def initialize(self, filename):
        require(not self.current.exists() and not self.pending(), "story is already initialized or pending")
        source = self.input(filename)
        validate_state(source["state"])
        validate_plan(source["plan"])
        text(source.get("foundation"), "story foundation")
        dt.date.fromisoformat(source["baseline_date"])
        require(source["baseline_date"] == self.date, "baseline date must match the inspected release date")
        require(source.get("evidence"), "baseline requires source evidence")
        snapshot = {"schema_version": 1, "kind": "baseline", "parent": None,
                    "baseline_date": self.date, "foundation": source["foundation"],
                    "state": source["state"], "plan": source["plan"],
                    "evidence": source["evidence"], "episode": 0,
                    "completed_beats": [], "promises": {},
                    "last_episode": {"date": self.date, "tag": self.tag,
                                     "native_dir": str(self.native), "number": 0}}
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.private, 0o700)
        os.chmod(self.root, 0o700)
        revision = self.save_revision(snapshot)
        self.point(revision)
        return {"initialized": True, "revision": revision, "episode": 0}

    def revise_plan(self, filename):
        require(not self.pending(), "finish the pending episode before revising the plan")
        revision, old = self.head()
        source = self.input(filename)
        require(source.get("base_revision") == revision, "stale plan revision")
        text(source.get("reason"), "plan revision reason")
        plan = source["plan"]
        validate_plan(plan, old["completed_beats"])
        old_arcs, _ = planning_calendar(old["plan"])
        new_arcs, new_seasons = planning_calendar(plan)
        if old_arcs:
            require(new_arcs, "planning cadence cannot be removed")
            for task in self.planning_status(old)["due"]:
                if task["kind"] == "arc-detail":
                    require(any(a["id"] == task["target_arc"] for a in new_arcs),
                            "a due planning checkpoint's target arc cannot be removed")
                elif task["kind"] == "season-outline":
                    require(any(s["id"] == task["season"] for s in new_seasons),
                            "a due planning checkpoint's season cannot be removed")
            for arc in old_arcs:
                if arc["first"] <= old["episode"]:
                    replacement = next((a for a in new_arcs if a["id"] == arc["id"]), None)
                    if arc["last"] <= old["episode"]:
                        require(replacement == arc, "completed arc boundaries must be preserved")
                    else:
                        require(replacement is not None and replacement["first"] == arc["first"] and
                                replacement["season"] == arc["season"] and replacement["last"] >= old["episode"],
                                "started arc order must be preserved")
            for review in old.get("planning_reviews", {}).values():
                self.check_planning_output(review["task"], plan)
        for beat in old["completed_beats"]:
            require(plan["beats"][beat] == old["plan"]["beats"][beat],
                    "established beat definitions cannot be rewritten")
        for key, history in old["promises"].items():
            require(key in plan["promises"], "a planted promise cannot be discarded")
            payoff_schedule = lambda outline: [e["number"] for e in outline["episodes"] if key in e["pays_off"]]
            if (plan["promises"][key] != old["plan"]["promises"][key] or
                    payoff_schedule(plan) != payoff_schedule(old["plan"])):
                text(source.get("promise_impacts", {}).get(key), "explanation for changed planted promise")
            if not history.get("paid_off"):
                target = plan["promises"][key]["target_beat"]
                require(target not in old["completed_beats"], "unpaid promise points to a completed beat")
                closing = [e["number"] for e in plan["episodes"]
                           if e["beat"] == target and e["completes_beat"]]
                require(not closing or any(n <= min(closing) for n in payoff_schedule(plan)),
                        "planned beat closure would strand a planted promise")
        previous = {e["number"]: e for e in old["plan"]["episodes"] if e["number"] <= old["episode"]}
        incoming = {e["number"]: e for e in plan["episodes"]}
        require(all(incoming.get(n) == e for n, e in previous.items()),
                "completed episode plans cannot be rewritten")
        new = copy.deepcopy(old)
        new["planning_obligations"] = self.planning_status(old)["due"]
        new.update(kind="plan", parent=revision, plan=plan,
                   revision_reason=source["reason"], promise_impacts=source.get("promise_impacts", {}))
        new_revision = self.save_revision(new)
        self.point(new_revision)
        return {"revision": new_revision, "episode": old["episode"]}

    def planning_status(self, head):
        arcs, seasons = planning_calendar(head["plan"])
        if not arcs:
            return {"enabled": False, "due": [], "upcoming": []}
        number = head["episode"]
        reviewed = head.get("planning_reviews", {})
        tasks = []
        for boundary in range(7, (number // 7 + 2) * 7, 7):
            tasks.append({"id": f"editorial:{boundary}", "kind": "editorial", "after_episode": boundary,
                          "evidence_episodes": list(range(boundary - 6, boundary + 1))})
        for previous, target in zip(arcs, arcs[1:]):
            tasks.append({"id": "arc-detail:" + target["id"], "kind": "arc-detail",
                          "after_episode": max(previous["first"] - 1, previous["last"] - 7),
                          "target_arc": target["id"]})
        for season in seasons:
            final_arc = next(a for a in reversed(arcs) if a["season"] == season["id"])
            tasks.append({"id": "season-outline:" + season["id"], "kind": "season-outline",
                          "after_episode": final_arc["first"] - 1, "season": season["id"]})
        by_id = {t["id"]: t for t in tasks}
        # Once due, a checkpoint survives an outline revision that moves its date.
        by_id.update({t["id"]: t for t in head.get("planning_obligations", [])})
        remaining = sorted((t for key, t in by_id.items() if key not in reviewed),
                           key=lambda t: (t["after_episode"], t["id"]))
        return {"enabled": True, "due": [t for t in remaining if t["after_episode"] <= number],
                "upcoming": [t for t in remaining if t["after_episode"] > number][:5],
                "completed_reviews": len(reviewed)}

    def check_planning_output(self, task, plan):
        arcs, seasons = planning_calendar(plan)
        if task["kind"] == "arc-detail":
            arc = next((a for a in arcs if a["id"] == task["target_arc"]), None)
            require(arc is not None, "a due or reviewed arc cannot be removed")
            episodes = {e["number"]: e for e in plan["episodes"]}
            require(all(n in episodes and plan["beats"][episodes[n]["beat"]]["arc"] == arc["id"]
                        for n in range(arc["first"], arc["last"] + 1)),
                    "fully detail the next arc through story-plan before recording its planning review")
        elif task["kind"] == "season-outline":
            index = next((i for i, s in enumerate(seasons) if s["id"] == task["season"]), None)
            require(index is not None and index + 1 < len(seasons),
                    "add the next season's broad outline and ordered arcs before recording its review")

    def review(self, filename):
        revision, head = self.head()
        source = self.input(filename)
        checkpoint = source.get("checkpoint")
        source_digest = digest(encoded(source))
        previous = head.get("planning_reviews", {}).get(checkpoint)
        if previous:
            require(previous["source_digest"] == source_digest, "planning review is already recorded with different content")
            return {"review_recorded": True, "checkpoint": checkpoint, "revision": revision}
        require(not self.pending(), "finish the pending episode before recording a planning review")
        require(source.get("base_revision") == revision, "stale planning review revision")
        task = next((t for t in self.planning_status(head)["due"] if t["id"] == checkpoint), None)
        require(task is not None, "planning checkpoint is not due")
        require(source.get("decision") in ("unchanged", "revised"), "review decision must be unchanged or revised")
        for field in ("pacing", "characters", "themes", "repetition", "setup_payoff", "continuity"):
            text(source.get("findings", {}).get(field), f"planning review: {field}")
        evidence = source.get("evidence_episodes")
        require(isinstance(evidence, list) and all(type(n) is int and 0 <= n <= head["episode"] for n in evidence),
                "review evidence must refer to committed episodes")
        if task["kind"] == "editorial":
            require(set(task["evidence_episodes"]) <= set(evidence), "review the full seven-episode window")
        else:
            require(evidence, "planning review needs established context evidence; episode 0 is the baseline")
        self.check_planning_output(task, head["plan"])
        new = copy.deepcopy(head)
        new.update(kind="planning-review", parent=revision)
        new.setdefault("planning_reviews", {})[checkpoint] = {
            "task": task, "at_episode": head["episode"], "source_digest": source_digest, "source": source}
        new["planning_obligations"] = [t for t in self.planning_status(head)["due"] if t["id"] != checkpoint]
        new_revision = self.save_revision(new)
        self.point(new_revision)
        return {"review_recorded": True, "checkpoint": checkpoint, "revision": new_revision}

    def correct_baseline(self, filename):
        revision, old = self.head()
        require(old["episode"] == 0 and not self.pending(),
                "baseline corrections are only allowed before the first episode is prepared")
        source = self.input(filename)
        require(source.get("base_revision") == revision, "stale baseline correction")
        text(source.get("reason"), "baseline correction evidence")
        validate_state(source["state"])
        for collection in old["state"]:
            require(set(old["state"][collection]) <= set(source["state"][collection]),
                    "baseline corrections must retain established record IDs")
        new = copy.deepcopy(old)
        new.update(kind="baseline-correction", parent=revision, state=source["state"],
                   revision_reason=source["reason"])
        new_revision = self.save_revision(new)
        self.point(new_revision)
        return {"baseline_corrected": True, "revision": new_revision, "episode": 0}

    def validate_episode(self, source, revision, old, final=False):
        require(source.get("base_revision") == revision, "stale episode base revision")
        require(source.get("number") == old["episode"] + 1, "episode must follow committed history")
        require(self.date > old["last_episode"]["date"], "episode date must advance committed history")
        planned = next((e for e in old["plan"]["episodes"] if e["number"] == source["number"]), None)
        require(planned is not None, "extend the versioned outline before planning this episode")
        require(source.get("beat") == planned["beat"], "episode must follow its planned beat")
        beat = old["plan"]["beats"][planned["beat"]]
        require(set(beat["requires"]) <= set(old["completed_beats"]), "beat setup is not complete")
        require(planned["beat"] not in old["completed_beats"], "beat is already complete")
        if planned["completes_beat"]:
            outstanding = {key for key, value in old["promises"].items()
                           if value.get("planted") and not value.get("paid_off") and
                           old["plan"]["promises"][key]["target_beat"] == planned["beat"]}
            require(outstanding <= set(planned["pays_off"]), "beat closure would strand a planted promise")
        for promise in planned["pays_off"]:
            require(old["promises"].get(promise, {}).get("planted"), "payoff has no committed setup")
            require(not old["promises"][promise].get("paid_off"), "promise was already paid off")
            require(old["plan"]["promises"][promise]["target_beat"] == planned["beat"],
                    "payoff must follow its planned destination")
        validate_state(source["after"])
        public = source.get("public", {})
        text(public.get("caption"), "public caption", 500)
        require("\n" not in public["caption"], "caption must be one line")
        text(public.get("prose"), "public prose", 6000)
        require(80 <= len(public["prose"].split()) <= 150, "public prose must contain 80 to 150 words")
        text(source.get("journal"), "private episode paragraph", 2000)
        require(len(source["journal"]) >= 120 and "\n" not in source["journal"],
                "journal must be one substantive paragraph")
        changes = source.get("changes")
        require(isinstance(changes, list), "episode requires explicit state changes")
        expected = set()
        for collection in old["state"]:
            before, after = old["state"][collection], source["after"][collection]
            require(set(before) <= set(after), "retain departed characters and retired facts; change their status")
            for key, record in after.items():
                clean = lambda value: {k: v for k, v in value.items() if not k.startswith("_")}
                if key not in before or clean(record) != clean(before[key]):
                    expected.add((collection, key))
                require(record.get("_episodes", []) == before.get(key, {}).get("_episodes", []),
                        "episode provenance is wrapper-owned")
        actual = set()
        for change in changes:
            pair = (change.get("collection"), change.get("id"))
            require(pair not in actual, "duplicate state change")
            actual.add(pair)
            for field in ("reason", "expression"):
                text(change.get(field), f"change {field}")
            require(change.get("channel") in ("image", "prose", "author"), "invalid expression channel")
            if pair[0] in ("characters", "threads"):
                require(change["channel"] != "author", "character and thread development must reach the viewer")
        require(actual == expected, "each changed record needs exactly one cause and expression")
        for field in ("journey", "character", "theme", "continuity"):
            text(source.get("purpose", {}).get(field), f"episode purpose: {field}")
        if final:
            for field in ("panorama", "character_evidence", "knowledge", "setup_payoff", "privacy"):
                text(source.get("review", {}).get(field), f"final review: {field}")
            evidence = source.get("promise_evidence", {})
            require(set(evidence) == set(planned["plants"] + planned["pays_off"]),
                    "each setup and payoff needs its own visible or public evidence")
            for value in evidence.values():
                text(value, "promise evidence")
        return planned

    def prepare(self, filename, final=False):
        require(self.enabled(), "new narrative episodes must follow the baseline date")
        require(self.run, "story preparation requires the owning run")
        self.guard()
        revision, old = self.head()
        if not final and not self.pending():
            require(not self.planning_status(old)["due"],
                    "planning checkpoints are due; finish story-plan/story-review before preparing the next episode")
        source = self.input(filename)
        self.validate_episode(source, revision, old, final)
        pending = self.pending()
        if final:
            require(pending is not None, "prepare the episode before final review")
            require(pending["phase"] != "publishing", "publication intent is frozen")
            for name, key in (("story.txt", "caption"), ("episode.txt", "prose")):
                path = self.staging / name
                if path.exists():
                    require(safe(path).read_text().strip() == source["public"][key],
                            "public text has already been accepted; preserve it during recovery")
        elif pending:
            require(pending["source"] == source, "episode already prepared; use story-finalize after review")
            return {"phase": pending["phase"], "number": source["number"]}
        # Preserve every accepted draft and final review, even after pending is cleared.
        record = {"date": self.date, "run": self.run, "phase": "ready" if final else "prepared", "source": source}
        write(self.root / "drafts" / (digest(encoded(record)) + ".json"), encoded(record), immutable=True)
        write(self.pending_path, encoded(record))
        return {"phase": record["phase"], "number": source["number"]}

    def export_public(self):
        if not self.enabled():
            return {"legacy": True}
        self.guard()
        pending = self.pending()
        if pending:
            require(pending["phase"] in ("ready", "publishing"), "finalize the reviewed episode before staging")
            public = pending["source"]["public"]
        else:
            episode = self.episode_for_date()
            require(episode is not None, "no reviewed episode exists for this date")
            public = episode["public"]
        for name, key in (("story.txt", "caption"), ("episode.txt", "prose")):
            write(self.staging / name, (public[key] + "\n").encode(), immutable=True, mode=0o644)
        return {"public_story_exported": True}

    def asset_manifest(self, notes):
        paths = [self.staging / f"landscape-{slot}.jpg" for slot in ("left", "middle", "right")]
        paths += [self.staging / "story.txt", self.staging / "episode.txt", Path(notes)]
        require(Path(notes).parent == self.staging, "release notes must belong to this episode")
        return {str(safe(path)): digest(path.read_bytes()) for path in paths}

    def freeze(self, notes):
        if not self.enabled():
            return {"legacy": True}
        self.guard()
        pending = self.pending()
        if not pending:
            require(self.episode_for_date() is not None, "no episode to publish")
            return {"already_committed": True}
        require(pending["phase"] in ("ready", "publishing"), "episode has not passed final review")
        manifest = self.asset_manifest(notes)
        if pending["phase"] == "publishing":
            require(pending["manifest"] == manifest, "frozen publication artifacts changed")
        else:
            pending.update(phase="publishing", manifest=manifest)
            write(self.pending_path, encoded(pending))
        return {"phase": "publishing", "number": pending["source"]["number"]}

    def append_journal(self, paragraph):
        path = self.private / "daily-continuity-log.md"
        existing = safe(path).read_text() if path.exists() else "# Private wallpaper continuity journal\n"
        header = f"## {self.date}"
        sections = re.split(r"(?m)^## (\d{4}-\d{2}-\d{2})\s*$", existing)
        for i in range(1, len(sections), 2):
            if sections[i] == self.date:
                require(sections[i + 1].strip() == paragraph, "existing journal entry conflicts with committed episode")
                return
        write(path, (existing.rstrip() + f"\n\n{header}\n\n{paragraph}\n").encode())

    def commit(self, notes):
        """Caller must first verify the exact remote release and its public text."""
        self.guard()
        revision, old = self.head()
        pending = self.pending()
        if not pending:
            episode = self.episode_for_date()
            require(episode is not None, "no published episode to commit")
            return {"story_committed": True, "episode": episode["number"], "revision": revision}
        require(pending["phase"] == "publishing", "publication intent must be saved before commit")
        require(pending["manifest"] == self.asset_manifest(notes), "publication artifacts changed after freeze")
        source = pending["source"]
        if old["last_episode"]["date"] == self.date:
            require(old["last_episode"]["source_digest"] == digest(encoded(source)), "committed episode differs")
        else:
            planned = self.validate_episode(source, revision, old, final=True)
            new = copy.deepcopy(old)
            after = copy.deepcopy(source["after"])
            for change in source["changes"]:
                after[change["collection"]][change["id"]].setdefault("_episodes", []).append(source["number"])
            new.update(kind="episode", parent=revision, state=after, episode=source["number"])
            if planned["completes_beat"]:
                new["completed_beats"].append(planned["beat"])
            for key in planned["plants"]:
                new["promises"].setdefault(key, {}).setdefault("planted", []).append(source["number"])
            for key in planned["pays_off"]:
                new["promises"][key]["paid_off"] = source["number"]
            new["last_episode"] = {"date": self.date, "tag": self.tag, "number": source["number"],
                                   "native_dir": str(self.native), "run": self.run,
                                   "public": source["public"], "journal": source["journal"],
                                   "source_digest": digest(encoded(source)), "manifest": pending["manifest"],
                                   "changes": source["changes"], "purpose": source["purpose"], "review": source["review"]}
            new["last_episode"]["promise_evidence"] = source.get("promise_evidence", {})
            new["planning_obligations"] = self.planning_status(new)["due"]
            revision = self.save_revision(new)
            self.point(revision)
        # If interrupted here, the same pending source repairs the journal on retry.
        self.append_journal(source["journal"])
        self.pending_path.unlink()
        sync_dir(self.root)
        return {"story_committed": True, "episode": source["number"], "revision": revision}

    def episode_for_date(self):
        if not self.current.exists():
            return None
        _, record = self.head()
        while True:
            if record["last_episode"]["date"] == self.date:
                return record["last_episode"]
            if not record["parent"]:
                return None
            record = self.revision(record["parent"])

    def correction(self, notes):
        """Called after supervised replacement passes exact-release validation."""
        if not self.enabled():
            return {"legacy": True}
        require(not self.pending(), "finish the pending episode before recording a correction")
        revision, old = self.head()
        episode = self.episode_for_date()
        require(episode is not None, "correction must refer to an established episode")
        correction = {"number": episode["number"], "date": self.date,
                      "native_dir": str(self.native), "manifest": self.asset_manifest(notes)}
        if old.get("correction") == correction:
            return {"correction_recorded": True, "episode": episode["number"], "revision": revision}
        new = copy.deepcopy(old)
        new.update(kind="correction", parent=revision, correction=correction)
        if old["last_episode"]["date"] == self.date:
            new["last_episode"].update(native_dir=str(self.native), manifest=correction["manifest"])
        new_revision = self.save_revision(new)
        self.point(new_revision)
        return {"correction_recorded": True, "episode": episode["number"], "revision": new_revision}

    def context(self):
        if not self.current.exists():
            return {"initialized": False, "open_runs": self.open_runs()}
        revision, head = self.head()
        next_number = head["episode"] + 1
        upcoming = [e for e in head["plan"]["episodes"] if e["number"] >= next_number][:5]
        plan = copy.deepcopy(head["plan"])
        plan["episodes"] = upcoming
        _, seasons = planning_calendar(head["plan"])
        active = next((s for s in seasons if s["first"] <= next_number <= s["last"]), None)
        if active:
            outline = active["outline"]
            plan.update(season=outline["title"], theme=outline["theme"], ending=outline["ending"],
                        character_destinations=outline["character_destinations"], transition=outline["transition"])
        remaining = {key for key in plan["beats"] if key not in head["completed_beats"]}
        needed = remaining | {b for key in remaining for b in plan["beats"][key]["requires"]}
        plan["beats"] = {key: value for key, value in plan["beats"].items() if key in needed}
        arcs = {beat["arc"] for beat in plan["beats"].values()}
        plan["arcs"] = {key: value for key, value in plan["arcs"].items() if key in arcs}
        plan["promises"] = {key: value for key, value in plan["promises"].items()
                            if not head["promises"].get(key, {}).get("paid_off") or
                            any(key in e["plants"] + e["pays_off"] for e in upcoming)}
        recent, cursor = [], revision
        while cursor and len(recent) < 3:
            item = self.revision(cursor)
            if item["kind"] == "episode":
                recent.append(item["last_episode"])
            cursor = item["parent"]
        relevant = set()
        for collection in head["state"].values():
            for record in collection.values():
                relevant.update(record.get("_episodes", [])[-1:])
        for promise in head["promises"].values():
            if not promise.get("paid_off"):
                relevant.update(promise.get("planted", []))
        return {"initialized": True, "revision": revision, "episode": head["episode"],
                "foundation": head["foundation"], "state": head["state"], "plan": plan,
                "completed_beats": head["completed_beats"], "promises": head["promises"],
                "last_episode": head["last_episode"], "recent_episodes": recent,
                "retrieve_episode_numbers": sorted(relevant), "pending": self.pending(),
                "open_runs": self.open_runs(),
                "planning": self.planning_status(head),
                "instruction": "Private author context. Read story-history NUMBER for older evidence needed today. Future plans are not established events."}

    def history(self, number):
        revision, head = self.head()
        corrections = []
        while True:
            if int(number) == 0 and head["kind"] in ("baseline", "baseline-correction"):
                return head
            if head["kind"] == "correction" and head["correction"]["number"] == int(number):
                corrections.append(head["correction"])
            if head["kind"] == "episode" and head["episode"] == int(number):
                return {"revision": revision, "episode": head["last_episode"], "corrections": corrections}
            if not head["parent"]:
                require(int(number) == 0, "episode not found")
                return head
            revision = head["parent"]
            head = self.revision(revision)

    def audit(self):
        revision, head = self.head()
        count, episodes, seen = 0, [], set()
        while revision:
            require(revision not in seen, "cyclic revision history")
            seen.add(revision)
            record = self.revision(revision)
            validate_state(record["state"])
            validate_plan(record["plan"], record["completed_beats"])
            if record["kind"] == "episode":
                episodes.append(record["episode"])
            count += 1
            revision = record["parent"]
        require(episodes == list(range(head["episode"], 0, -1)), "episode history is not contiguous")
        return {"story_valid": True, "episode": head["episode"], "revisions": count,
                "pending": self.pending() is not None}


def main():
    story = Story()
    command, *args = sys.argv[1:]
    if command == "enabled":
        return 0 if story.enabled() else 1
    if command == "guard":
        story.guard()
        return 0
    if command == "require-prepared":
        if story.enabled():
            story.guard()
            require(story.pending() is not None or story.episode_for_date() is not None,
                    "prepare the story episode before accepting new images")
        return 0
    commands = {"init": story.initialize, "plan": story.revise_plan, "baseline-correction": story.correct_baseline,
                "review": story.review,
                "prepare": story.prepare, "finalize": lambda f: story.prepare(f, final=True),
                "context": story.context, "history": story.history, "audit": story.audit,
                "export": story.export_public, "freeze": story.freeze, "commit": story.commit,
                "correction": story.correction}
    if command == "outline":
        revision, head = story.head()
        result = {"base_revision": revision, "plan": head["plan"]}
    elif command == "reference":
        result = (story.episode_for_date() or story.head()[1]["last_episode"]) if story.current.exists() else {}
    elif command == "complete":
        if story.enabled():
            require(story.episode_for_date() is not None and not story.pending(),
                    "published episode still needs story-commit")
        result = {"story_committed": story.enabled()}
    else:
        require(command in commands, "unknown story command")
        result = commands[command](*args)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (StoryError, OSError, ValueError, KeyError, TypeError) as error:
        # Input documents may contain spoilers; never echo their contents on errors.
        message = str(error) if isinstance(error, StoryError) else type(error).__name__
        print("ERROR: " + message, file=sys.stderr)
        sys.exit(2)
