#!/usr/bin/env python3
"""Isolated narrative behavior and crash-recovery tests; no production inputs."""
import copy
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("narrative", Path(__file__).parents[1] / "producer/narrative.py")
narrative = importlib.util.module_from_spec(spec)
spec.loader.exec_module(narrative)

PROSE = ("The expedition stopped where the old channel divided. One traveler held the lantern over "
         "the dry stones while the other followed the sound of water beneath them. They had spent "
         "the morning searching for a crossing, but the smallest opening offered a different task. "
         "Together they lifted a fallen marker and let a thin current pass. Neither knew how far "
         "it would travel. For now, they sat beside the opening and watched the first pale leaves "
         "turn toward it. The road could wait until they understood what their small repair had begun.")


def character(name="Fixture traveler"):
    return {"description": "A synthetic traveler learning to share decisions.", "status": "traveling",
            "name": name, "name_revealed": False, "visual": "A triangular cloak and round lantern.",
            "desire": "Reach the far shore.", "belief": "A good route can be chosen alone.", "relationships": {}}


def baseline(count=2, date="2099-01-02"):
    return {"baseline_date": date, "foundation": "Synthetic thematic journey; the cast may evolve.",
            "evidence": ["Synthetic fixture release; contains no real narrative context."],
            "state": {"characters": {"traveler": character()},
                      "facts": {"channel": {"description": "The channel has a hidden source.", "status": "active",
                                            "audience_knows": False, "known_by": []}}, "threads": {}},
            "plan": {"season": "Fixture season", "ending": "The travelers choose to share the crossing.",
                     "theme": "Care and control", "character_destinations": "The traveler accepts shared decisions.",
                     "arcs": {"crossing": {"objective": "Find a crossing.", "conflict": "Control or cooperation.",
                                            "resolution": "A shared crossing opens."}},
                     "beats": {"setup": {"arc": "crossing", "purpose": "Establish a promise.", "requires": []},
                               "choice": {"arc": "crossing", "purpose": "Earn the shared choice.", "requires": ["setup"]}},
                     "promises": {"lantern": {"setup": "A lantern is offered.", "payoff": "It is returned freely.",
                                               "target_beat": "choice"}},
                     "episodes": [{"number": n, "beat": "setup" if n == 1 else "choice",
                                   "purpose": "Observe, act, and retain consequences.",
                                   "visible_action": "The travelers make one small change beside the channel.",
                                   "completes_beat": n in (1, count),
                                   "plants": ["lantern"] if n == 1 else [],
                                   "pays_off": ["lantern"] if n == count else []} for n in range(1, count + 1)]}}


def episode(story):
    revision, head = story.head()
    number = head["episode"] + 1
    planned = next(e for e in head["plan"]["episodes"] if e["number"] == number)
    after = copy.deepcopy(head["state"])
    after["characters"]["traveler"]["belief"] = f"The shared crossing has taught lesson {number}."
    changes = [{"collection": "characters", "id": "traveler", "reason": "Help was freely offered.",
                "expression": "The traveler accepts the other person's hand beside the opening.", "channel": "prose"}]
    return {"base_revision": revision, "number": number, "beat": planned["beat"],
            "public": {"caption": "The travelers pause beside the divided channel.", "prose": PROSE},
            "after": after, "changes": changes,
            "promise_evidence": {key: "The public episode shows the offered or returned lantern."
                                 for key in planned["plants"] + planned["pays_off"]},
            "journal": "The synthetic traveler accepted help at the channel. This establishes a small change in belief while preserving the source of the water as an unrevealed fact.",
            "purpose": {"journey": "Explore the channel.", "character": "Accept offered help.",
                        "theme": "Test care without control.", "continuity": "The original lantern remains present."},
            "review": {"panorama": "Synthetic fixture panorama checked.", "character_evidence": "Public prose expresses the change.",
                       "knowledge": "The hidden source remains unknown.", "setup_payoff": "The offered lantern sets up a return.",
                       "privacy": "Only separately authored public prose is exported."}}


class NarrativeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="wallpaper-story-test-")
        self.root = Path(self.temp.name)
        self.env = patch.dict(os.environ, {
            "AI_WALLPAPERS_WORKSPACE_ROOT": str(self.root), "AI_WALLPAPERS_PRIVATE_ROOT": str(self.root / "private"),
            "AI_WALLPAPERS_INPUT_ROOT": str(self.root / "input"), "AI_WALLPAPERS_STAGING_ROOT": str(self.root / "staging"),
            "AI_WALLPAPERS_NATIVE_ROOT": str(self.root / "native"), "AI_WALLPAPERS_RUN_DATE": "2099-01-02",
            "AI_WALLPAPERS_RUN_ID": "fixture-run"})
        self.env.start()
        self.story = narrative.Story()
        self.story.initialize(self.put("baseline", baseline(count=21)))
        self.next_day()

    def tearDown(self):
        self.env.stop()
        self.temp.cleanup()

    def put(self, name, value):
        path = self.root / "input" / (name + ".json")
        path.parent.mkdir(exist_ok=True)
        path.write_text(json.dumps(value))
        return str(path)

    def next_day(self, skip=1):
        date = dt.date.fromisoformat(os.environ["AI_WALLPAPERS_RUN_DATE"]) + dt.timedelta(days=skip)
        os.environ["AI_WALLPAPERS_RUN_DATE"] = date.isoformat()
        self.story = narrative.Story()

    def ready(self, source=None):
        source = source or episode(self.story)
        filename = self.put("episode", source)
        self.story.prepare(filename)
        self.story.prepare(filename, final=True)
        self.story.export_public()
        notes = self.story.staging / "release-notes.txt"
        notes.write_text(source["public"]["caption"] + "\n" + source["public"]["prose"])
        for slot in ("left", "middle", "right"):
            (self.story.staging / f"landscape-{slot}.jpg").write_bytes(b"isolated fixture asset")
        self.story.freeze(str(notes))
        return notes

    def test_failed_preparation_never_advances_history_and_blocks_next_day(self):
        original = self.story.head()[0]
        self.story.prepare(self.put("episode", episode(self.story)))
        self.assertEqual(self.story.head()[0], original)
        self.next_day()
        with self.assertRaisesRegex(narrative.StoryError, "resume that date"):
            self.story.guard()

    def test_payoff_requires_committed_setup(self):
        source = episode(self.story)
        source["beat"] = "choice"
        with self.assertRaises(narrative.StoryError):
            self.story.prepare(self.put("bad", source))
        rev, head = self.story.head()
        plan = copy.deepcopy(head["plan"])
        plan["episodes"][0]["pays_off"] = ["lantern"]
        plan["promises"]["lantern"]["target_beat"] = "setup"
        plan["episodes"][-1]["pays_off"] = []
        self.story.revise_plan(self.put("plan", {"base_revision": rev, "reason": "Test missing setup.", "plan": plan}))
        with self.assertRaisesRegex(narrative.StoryError, "no committed setup"):
            self.story.prepare(self.put("bad", episode(self.story)))

    def test_stale_plan_and_unexplained_changes_rejected(self):
        source = episode(self.story)
        source["base_revision"] = "0" * 64
        with self.assertRaisesRegex(narrative.StoryError, "stale"):
            self.story.prepare(self.put("bad", source))
        source = episode(self.story)
        source["changes"] = []
        with self.assertRaisesRegex(narrative.StoryError, "each changed record"):
            self.story.prepare(self.put("bad", source))

    def test_interruption_after_remote_publish_and_after_head_commit(self):
        notes = self.ready()
        # Publication is known to the caller, but local history is still unchanged.
        self.assertEqual(self.story.head()[1]["episode"], 0)
        with patch.object(self.story, "append_journal", side_effect=OSError("simulated power loss")):
            with self.assertRaises(OSError):
                self.story.commit(str(notes))
        self.assertEqual(self.story.head()[1]["episode"], 1)
        self.assertIsNotNone(self.story.pending())
        self.story.commit(str(notes))
        self.story.commit(str(notes))
        journal = (self.story.private / "daily-continuity-log.md").read_text()
        self.assertEqual(journal.count("## 2099-01-03"), 1)
        self.assertEqual(self.story.audit()["episode"], 1)
        self.assertIsNone(self.story.pending())

    def test_interruption_before_head_update_reuses_immutable_snapshot(self):
        notes = self.ready()
        with patch.object(self.story, "point", side_effect=OSError("simulated power loss")):
            with self.assertRaises(OSError):
                self.story.commit(str(notes))
        count = len(list((self.story.root / "revisions").glob("*.json")))
        self.story.commit(str(notes))
        self.assertEqual(len(list((self.story.root / "revisions").glob("*.json"))), count)

    def test_frozen_publication_rejects_changed_assets(self):
        notes = self.ready()
        (self.story.staging / "landscape-left.jpg").write_bytes(b"changed")
        with self.assertRaisesRegex(narrative.StoryError, "artifacts changed"):
            self.story.commit(str(notes))
        self.assertEqual(self.story.head()[1]["episode"], 0)

    def test_three_week_arc_retains_cast_and_knowledge_changes(self):
        for number in range(1, 22):
            source = episode(self.story)
            if number == 4:
                source["after"]["characters"]["companion"] = character("New companion")
                source["changes"].append({"collection": "characters", "id": "companion", "reason": "A new traveler joins.",
                                          "expression": "A second silhouette enters the scene.", "channel": "image"})
            if number == 8:
                source["after"]["facts"]["channel"].update(audience_knows=True, known_by=["traveler"])
                source["changes"].append({"collection": "facts", "id": "channel", "reason": "The source is discovered.",
                                          "expression": "The source appears beyond the opening.", "channel": "image"})
            if number == 21:
                source["after"]["characters"]["traveler"]["status"] = "departed"
                source["changes"][0]["expression"] = "The traveler leaves the lantern and takes a separate road."
            notes = self.ready(source)
            self.story.commit(str(notes))
            self.next_day(skip=3 if number == 10 else 1)
        _, head = self.story.head()
        self.assertEqual(head["episode"], 21)
        self.assertEqual(head["state"]["characters"]["traveler"]["status"], "departed")
        self.assertIn("companion", head["state"]["characters"])
        self.assertEqual(head["state"]["facts"]["channel"]["known_by"], ["traveler"])
        self.assertEqual(head["promises"]["lantern"]["paid_off"], 21)
        self.assertEqual(self.story.history(8)["episode"]["number"], 8)
        self.assertEqual(self.story.audit()["episode"], 21)
        self.assertEqual(len(self.story.context()["recent_episodes"]), 3)
        # Planted promises survive outline revisions; established plans stay fixed.
        plan = copy.deepcopy(head["plan"])
        del plan["promises"]["lantern"]
        for item in plan["episodes"]:
            item["plants"], item["pays_off"] = [], []
        with self.assertRaises(narrative.StoryError):
            self.story.revise_plan(self.put("plan", {"base_revision": self.story.head()[0], "reason": "Drop setup.", "plan": plan}))

    def test_private_plan_never_exported_and_symlinks_rejected(self):
        notes = self.ready()
        exported = " ".join(p.read_text() for p in self.story.staging.glob("*.txt"))
        self.assertNotIn("hidden source", exported)
        self.assertNotIn("Fixture season", exported)
        self.story.commit(str(notes))
        target = self.root / "outside"
        target.write_text("private target")
        self.story.current.unlink()
        self.story.current.symlink_to(target)
        with self.assertRaisesRegex(narrative.StoryError, "symlink"):
            self.story.head()

    def test_outline_cannot_silently_drop_or_strand_an_earned_payoff(self):
        self.story.commit(str(self.ready()))
        revision, head = self.story.head()
        plan = copy.deepcopy(head["plan"])
        plan["episodes"][-1]["pays_off"] = []
        source = {"base_revision": revision, "plan": plan, "reason": "Change the closing scene."}
        with self.assertRaisesRegex(narrative.StoryError, "explanation"):
            self.story.revise_plan(self.put("plan", source))
        source["promise_impacts"] = {"lantern": "The lantern will return in a later scene."}
        with self.assertRaisesRegex(narrative.StoryError, "strand"):
            self.story.revise_plan(self.put("plan", source))

    def test_supervised_art_correction_preserves_episode_and_state(self):
        notes = self.ready()
        self.story.commit(str(notes))
        before = copy.deepcopy(self.story.head()[1]["state"])
        self.story.native = self.root / "native-revision" / self.story.tag
        self.story.staging = self.root / "staging-revision" / self.story.tag
        self.story.export_public()
        notes = self.story.staging / "release-notes.txt"
        notes.write_text(PROSE)
        for slot in ("left", "middle", "right"):
            (self.story.staging / f"landscape-{slot}.jpg").write_bytes(b"corrected synthetic panel")
        result = self.story.correction(str(notes))
        self.assertEqual(result["episode"], 1)
        self.assertEqual(self.story.head()[1]["state"], before)
        self.assertEqual(self.story.head()[1]["last_episode"]["native_dir"], str(self.story.native))
        self.assertEqual(self.story.correction(str(notes))["revision"], result["revision"])
        self.assertEqual(len(self.story.history(1)["corrections"]), 1)
        self.assertEqual(self.story.audit()["episode"], 1)

    def test_migration_correction_is_versioned_and_closes_before_episode_one(self):
        revision, head = self.story.head()
        state = copy.deepcopy(head["state"])
        state["facts"]["channel"]["description"] = "The source is unknown; no particular character has seen it."
        source = {"base_revision": revision, "state": state, "reason": "Correct an unsupported knowledge inference."}
        self.story.correct_baseline(self.put("baseline-fix", source))
        self.assertEqual(self.story.history(0)["kind"], "baseline-correction")
        self.assertEqual(self.story.audit()["revisions"], 2)
        self.story.prepare(self.put("episode", episode(self.story)))
        with self.assertRaisesRegex(narrative.StoryError, "before the first episode"):
            self.story.correct_baseline(self.put("baseline-fix", source))

    def cadence_plan(self, detailed=False):
        plan = copy.deepcopy(self.story.head()[1]["plan"])
        for key in ("second", "third", "fourth"):
            plan["arcs"][key] = {"objective": "Continue a synthetic journey.", "conflict": "Test shared choices.",
                                  "resolution": "Retain the consequence of the choice."}
            plan["beats"][key + "-beat"] = {"arc": key, "purpose": "Develop the next planned arc.", "requires": []}
        plan["seasons"] = [{"id": "season-one", "title": "Fixture season", "theme": plan["theme"],
                            "ending": plan["ending"], "character_destinations": plan["character_destinations"],
                            "transition": "Continue the established journey.",
                            "arcs": [{"id": key, "episodes": 21} for key in ("crossing", "second", "third", "fourth")]}]
        if detailed:
            for key in ("second", "third", "fourth"):
                self.detail_arc(plan, key)
        return plan

    def detail_arc(self, plan, key):
        arcs, _ = narrative.planning_calendar(plan)
        arc = next(a for a in arcs if a["id"] == key)
        for number in range(arc["first"], arc["last"] + 1):
            plan["episodes"].append({"number": number, "beat": key + "-beat", "purpose": "Test persistence.",
                                     "visible_action": "A traveler carries a changed lantern onward.",
                                     "completes_beat": number == arc["last"], "plants": [], "pays_off": []})
        plan["episodes"].sort(key=lambda e: e["number"])

    def update_plan(self, plan):
        return self.story.revise_plan(self.put("cadence-plan", {"base_revision": self.story.head()[0],
                                                               "reason": "Refine the synthetic future outline.", "plan": plan}))

    def review_source(self, task):
        revision, head = self.story.head()
        return {"base_revision": revision, "checkpoint": task["id"], "decision": "unchanged",
                "evidence_episodes": task.get("evidence_episodes", [head["episode"]]),
                "findings": {field: "Synthetic evidence supports retaining the planned destination."
                             for field in ("pacing", "characters", "themes", "repetition", "setup_payoff", "continuity")}}

    def service_reviews(self):
        while self.story.context()["planning"]["due"]:
            task = self.story.context()["planning"]["due"][0]
            self.story.review(self.put("review", self.review_source(task)))

    def advance_to(self, number):
        while self.story.head()[1]["episode"] < number:
            self.service_reviews()
            self.story.commit(str(self.ready()))
            self.next_day(skip=3)

    def test_editorial_review_follows_completed_episodes_and_survives_retries(self):
        self.update_plan(self.cadence_plan())
        self.advance_to(6)
        self.assertEqual(self.story.context()["planning"]["due"], [])
        notes = self.ready()
        self.assertEqual(self.story.context()["planning"]["due"], [])
        with patch.object(self.story, "append_journal", side_effect=OSError("interrupted commit")):
            with self.assertRaises(OSError):
                self.story.commit(str(notes))
        task = self.story.context()["planning"]["due"][0]
        self.assertEqual(task["id"], "editorial:7")
        with self.assertRaisesRegex(narrative.StoryError, "finish the pending episode"):
            self.story.review(self.put("review", self.review_source(task)))
        self.story.commit(str(notes))
        self.next_day()
        with self.assertRaisesRegex(narrative.StoryError, "checkpoints are due"):
            self.story.prepare(self.put("episode", episode(self.story)))
        source = self.review_source(task)
        filename = self.put("review", source)
        state = copy.deepcopy(self.story.head()[1]["state"])
        with patch.object(self.story, "point", side_effect=OSError("interrupted review")):
            with self.assertRaises(OSError):
                self.story.review(filename)
        result = self.story.review(filename)
        self.assertEqual(self.story.review(filename)["revision"], result["revision"])
        self.assertEqual(self.story.head()[1]["episode"], 7)
        self.assertEqual(self.story.head()[1]["state"], state)
        self.story.prepare(self.put("episode", episode(self.story)))
        self.assertEqual(self.story.audit()["episode"], 7)

    def test_arc_review_requires_all_next_arc_episodes_and_protects_them(self):
        self.update_plan(self.cadence_plan())
        self.advance_to(14)
        due = {t["id"]: t for t in self.story.context()["planning"]["due"]}
        self.assertEqual(set(due), {"editorial:14", "arc-detail:second"})
        task = due["arc-detail:second"]
        with self.assertRaisesRegex(narrative.StoryError, "fully detail"):
            self.story.review(self.put("review", self.review_source(task)))
        plan = copy.deepcopy(self.story.head()[1]["plan"])
        self.detail_arc(plan, "second")
        self.update_plan(plan)
        self.service_reviews()
        self.assertEqual(self.story.context()["planning"]["due"], [])
        plan = copy.deepcopy(self.story.head()[1]["plan"])
        plan["episodes"] = [e for e in plan["episodes"] if e["number"] != 30]
        with self.assertRaisesRegex(narrative.StoryError, "fully detail"):
            self.update_plan(plan)

    def test_next_season_outline_is_due_before_the_final_arc(self):
        self.update_plan(self.cadence_plan(detailed=True))
        self.advance_to(63)
        due = {t["id"]: t for t in self.story.context()["planning"]["due"]}
        self.assertIn("season-outline:season-one", due)
        task = due["season-outline:season-one"]
        with self.assertRaisesRegex(narrative.StoryError, "next season"):
            self.story.review(self.put("review", self.review_source(task)))
        plan = copy.deepcopy(self.story.head()[1]["plan"])
        plan["arcs"]["fifth"] = {"objective": "Choose a new shore.", "conflict": "Carry earlier obligations.",
                                  "resolution": "Choose another shared direction."}
        plan["seasons"].append({"id": "season-two", "title": "The next fixture season", "theme": "Belonging and change.",
                                "ending": "Another earned departure.", "character_destinations": "Retain and deepen shared agency.",
                                "transition": "Carry the changed lantern into a new place.", "arcs": [{"id": "fifth", "episodes": 21}]})
        self.update_plan(plan)
        self.service_reviews()
        self.assertEqual(self.story.context()["plan"]["season"], "Fixture season")
        upcoming = self.story.context()["planning"]["upcoming"]
        self.assertIn({"id": "arc-detail:fifth", "kind": "arc-detail", "after_episode": 77, "target_arc": "fifth"}, upcoming)
        self.assertEqual(self.story.audit()["episode"], 63)

    def test_due_reviews_survive_rescheduling_and_cadence_cannot_disappear(self):
        self.update_plan(self.cadence_plan())
        self.advance_to(14)
        plan = copy.deepcopy(self.story.head()[1]["plan"])
        plan["seasons"][0]["arcs"][0]["episodes"] = 22
        final = copy.deepcopy(plan["episodes"][-1])
        final.update(number=22, pays_off=[])
        plan["episodes"][-1]["completes_beat"] = False
        plan["episodes"].append(final)
        self.update_plan(plan)
        task = next(t for t in self.story.context()["planning"]["due"] if t["kind"] == "arc-detail")
        self.assertEqual(task["after_episode"], 14)
        plan.pop("seasons")
        with self.assertRaisesRegex(narrative.StoryError, "cannot be removed"):
            self.update_plan(plan)

    def test_due_arc_target_cannot_be_removed_before_its_review(self):
        self.update_plan(self.cadence_plan())
        self.advance_to(14)
        revision, head = self.story.head()
        plan = copy.deepcopy(head["plan"])
        del plan["arcs"]["second"]
        del plan["beats"]["second-beat"]
        plan["seasons"][0]["arcs"] = [a for a in plan["seasons"][0]["arcs"] if a["id"] != "second"]
        with self.assertRaisesRegex(narrative.StoryError, "target arc cannot be removed"):
            self.update_plan(plan)
        self.assertEqual(self.story.head()[0], revision)

    def test_review_rejects_premature_or_incomplete_evidence(self):
        self.update_plan(self.cadence_plan())
        task = self.story.context()["planning"]["upcoming"][0]
        with self.assertRaisesRegex(narrative.StoryError, "not due"):
            self.story.review(self.put("review", self.review_source(task)))
        self.advance_to(7)
        task = self.story.context()["planning"]["due"][0]
        source = self.review_source(task)
        source["evidence_episodes"] = [7]
        with self.assertRaisesRegex(narrative.StoryError, "full seven"):
            self.story.review(self.put("review", source))
        source["evidence_episodes"] = list(range(1, 9))
        with self.assertRaisesRegex(narrative.StoryError, "committed episodes"):
            self.story.review(self.put("review", source))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--fixture":
        root, phase = Path(sys.argv[2]), sys.argv[3]
        value = baseline() if phase == "baseline" else episode(narrative.Story())
        (root / "input" / (phase + ".json")).write_text(json.dumps(value))
    else:
        unittest.main()
