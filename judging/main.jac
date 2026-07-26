"""JacHacks Judging Platform — Built with Jac."""

import from datetime { datetime }
import uuid;
import json;

# ── Enums ──

enum Track {
    AGENTIC_AI = "agentic_ai",
    FINTECH_OPEN = "fintech_open",
    SOCIAL_IMPACT = "social_impact"
}

enum Role {
    JUDGE = "judge",
    ORGANIZER = "organizer",
    SPONSOR_REP = "sponsor_rep",
    PARTICIPANT = "participant"
}

# ── Edges ──

edge HasConfig {}
edge HasProject {}
edge HasProfile {}
edge HasAward {}
edge HasScore {}
edge HasAwardScore {}
edge AssignedTo {
    has round_num: int = 1;
}

# ── Nodes ──

node Config {
    has scoring_locked: bool = False,
        event_name: str = "JacHacks 2026",
        current_group: int = 0,
        current_round: int = 0,
        total_groups: int = 0,
        group_size: int = 10,
        finals_selected: bool = False,
        finalists_per_track: int = 2;
}

node Project {
    has project_id: str = "",
        name: str = "",
        team_name: str = "",
        track: str = "",
        github_url: str = "",
        demo_url: str = "",
        devpost_url: str = "",
        description: str = "",
        submitted_by: str = "",
        submitted_at: str = "",
        group_num: int = 0,
        table_num: int = 0,
        is_finalist: bool = False,
        finalist_rank: int = 0;
}

node UserProfile {
    has user_id: str = "",
        name: str = "",
        email: str = "",
        role: str = "",
        assigned_tracks: list = [],
        sponsor_award_id: str = "";
}

node Score {
    has score_id: str = "",
        judge_id: str = "",
        project_id: str = "",
        technical_execution: int = 0,
        jac_usage: int = 0,
        creativity: int = 0,
        presentation: int = 0,
        notes: str = "",
        is_final: bool = False,
        round_num: int = 1,
        updated_at: str = "";
}

node SpecialAward {
    has award_id: str = "",
        name: str = "",
        sponsor: str = "",
        prize_description: str = "",
        winner_project_id: str = "";
}

node AwardScore {
    has award_score_id: str = "",
        judge_id: str = "",
        award_id: str = "",
        project_id: str = "",
        score: float = 0.0,
        notes: str = "",
        is_final: bool = False;
}

# ── Scoring weights ──

glob WEIGHT_TECHNICAL: float = 0.35;
glob WEIGHT_JAC_USAGE: float = 0.30;
glob WEIGHT_CREATIVITY: float = 0.20;
glob WEIGHT_PRESENTATION: float = 0.15;
glob TIE_THRESHOLD: float = 0.3;

# ── Helper functions ──

def compute_weighted_score(s: Score) -> float {
    return (
        s.technical_execution * WEIGHT_TECHNICAL +
        s.jac_usage * WEIGHT_JAC_USAGE +
        s.creativity * WEIGHT_CREATIVITY +
        s.presentation * WEIGHT_PRESENTATION
    );
}

def find_profile_by_email(email: str) -> UserProfile | None {
    for p in [root -->](?:UserProfile) {
        if p.email == email {
            return p;
        }
    }
    return None;
}

def find_project_by_id(pid: str) -> Project | None {
    for p in [root -->](?:Project) {
        if p.project_id == pid {
            return p;
        }
    }
    return None;
}

def find_award_by_id(aid: str) -> SpecialAward | None {
    for a in [root -->](?:SpecialAward) {
        if a.award_id == aid {
            return a;
        }
    }
    return None;
}

def get_config_node() -> Config {
    configs = [root -->](?:Config);
    if len(configs) > 0 {
        return configs[0];
    }
    c = Config();
    root +>:HasConfig:+> c;
    return c;
}

def project_to_dict(p: Project) -> dict {
    return {
        "project_id": p.project_id,
        "name": p.name,
        "team_name": p.team_name,
        "track": p.track,
        "github_url": p.github_url,
        "demo_url": p.demo_url,
        "devpost_url": p.devpost_url,
        "description": p.description,
        "submitted_by": p.submitted_by,
        "submitted_at": p.submitted_at,
        "group_num": p.group_num,
        "table_num": p.table_num,
        "is_finalist": p.is_finalist,
        "finalist_rank": p.finalist_rank
    };
}

"""Weighted score for one judge on one project, or None if they have no final score."""
def judge_weighted_for(proj: Project, judge_id: str, round_num: int) -> float | None {
    for s in [proj -->](?:Score) {
        if s.judge_id == judge_id and s.round_num == round_num and s.is_final {
            return compute_weighted_score(s);
        }
    }
    return None;
}

"""
Per-judge z-score normalization for one round.

Round 1 splits ~60 projects across ~10 judge pairs, so a project's raw average
depends heavily on which pair happened to score it. Converting each judge's
scores to z-scores against their own mean/spread removes that bias before we
compare projects across groups. Returns {judge_id: {project_id: z}}.
"""
def build_normalized_scores(round_num: int) -> dict {
    import math;
    projects = [root -->](?:Project);
    by_judge: dict = {};
    for proj in projects {
        for s in [proj -->](?:Score) {
            if s.round_num != round_num or not s.is_final {
                continue;
            }
            if s.judge_id not in by_judge {
                by_judge[s.judge_id] = {};
            }
            by_judge[s.judge_id][s.project_id] = compute_weighted_score(s);
        }
    }
    normalized: dict = {};
    for (judge_id, scores) in by_judge.items() {
        values = list(scores.values());
        n = len(values);
        mean = sum(values) / n;
        variance = sum([(v - mean) ** 2 for v in values]) / n;
        sd = math.sqrt(variance);
        normalized[judge_id] = {};
        for (pid, v) in scores.items() {
            # A judge with one score, or who gave everyone the same marks, carries
            # no comparative signal — treat them as exactly average rather than
            # dividing by zero.
            normalized[judge_id][pid] = 0.0 if n < 2 or sd == 0.0 else (v - mean) / sd;
        }
    }
    return normalized;
}

"""Ranked entries per track for a round. Each entry carries raw + normalized scores."""
def build_rankings(round_num: int, finalists_only: bool, sort_by: str) -> list {
    normalized = build_normalized_scores(round_num);
    projects = [root -->](?:Project);
    if finalists_only {
        projects = [p for p in projects if p.is_finalist];
    }
    tracks_data: dict = {};
    for proj in projects {
        scores = [
            s for s in [proj -->](?:Score)
            if s.is_final and s.round_num == round_num
        ];
        raw = 0.0;
        norm = 0.0;
        if len(scores) > 0 {
            raw = sum([compute_weighted_score(s) for s in scores]) / len(scores);
            zs = [
                normalized[s.judge_id][proj.project_id]
                for s in scores
                if s.judge_id in normalized
                and proj.project_id in normalized[s.judge_id]
            ];
            norm = sum(zs) / len(zs) if len(zs) > 0 else 0.0;
        }
        t = proj.track;
        if t not in tracks_data {
            tracks_data[t] = [];
        }
        tracks_data[t].append({
            "project_id": proj.project_id,
            "name": proj.name,
            "team_name": proj.team_name,
            "group_num": proj.group_num,
            "table_num": proj.table_num,
            "is_finalist": proj.is_finalist,
            "avg_score": round(raw, 2),
            "norm_score": round(norm, 3),
            "num_judges": len(scores),
            "tie_alert": False
        });
    }
    key = "avg_score" if sort_by == "raw" else "norm_score";
    result = [];
    for (t, entries) in tracks_data.items() {
        # Unscored projects all normalize to 0.0, which would otherwise sort them
        # above genuinely below-average teams. Sink them to the bottom.
        entries.sort(
            key=lambda e: dict: (1 if e["num_judges"] > 0 else 0, e[key]),
            reverse=True
        );
        for (i, e) in enumerate(entries) {
            e["rank"] = i + 1;
        }
        if len(entries) >= 2 {
            diff = entries[0][key] - entries[1][key];
            if diff <= TIE_THRESHOLD {
                entries[0]["tie_alert"] = True;
                entries[1]["tie_alert"] = True;
            }
        }
        result.append({"track": t, "rankings": entries});
    }
    result.sort(key=lambda x: dict: x["track"]);
    return result;
}

def score_to_dict(s: Score) -> dict {
    return {
        "score_id": s.score_id,
        "judge_id": s.judge_id,
        "project_id": s.project_id,
        "technical_execution": s.technical_execution,
        "jac_usage": s.jac_usage,
        "creativity": s.creativity,
        "presentation": s.presentation,
        "weighted_score": compute_weighted_score(s),
        "notes": s.notes,
        "is_final": s.is_final,
        "round_num": s.round_num,
        "updated_at": s.updated_at
    };
}

def profile_to_dict(p: UserProfile) -> dict {
    return {
        "user_id": p.user_id,
        "name": p.name,
        "email": p.email,
        "role": p.role,
        "assigned_tracks": p.assigned_tracks,
        "sponsor_award_id": p.sponsor_award_id
    };
}

def award_to_dict(a: SpecialAward) -> dict {
    return {
        "award_id": a.award_id,
        "name": a.name,
        "sponsor": a.sponsor,
        "prize_description": a.prize_description,
        "winner_project_id": a.winner_project_id
    };
}

# ══════════════════════════════════════════
# WALKER IMPLEMENTATIONS
# ══════════════════════════════════════════

# ── Health Check ──

walker:pub health {
    can check with Root entry {
        report {"status": "ok", "event": "JacHacks 2026"};
    }
}

# ── Config ──

walker:pub get_config {
    can fetch with Root entry {
        c = get_config_node();
        report {
            "scoring_locked": c.scoring_locked,
            "event_name": c.event_name,
            "current_group": c.current_group,
            "current_round": c.current_round,
            "total_groups": c.total_groups,
            "group_size": c.group_size,
            "finals_selected": c.finals_selected,
            "finalists_per_track": c.finalists_per_track
        };
    }
}

# ── Profile ──

walker:pub get_profile {
    has email: str = "";

    can fetch with Root entry {
        p = find_profile_by_email(self.email);
        if p != None {
            report profile_to_dict(p);
        } else {
            report {"error": "Profile not found"};
        }
    }
}

# ── Import Projects ──

walker:pub import_projects {
    has projects_json: str = "";

    can import_data with Root entry {
        try {
            items = json.loads(self.projects_json);
        } except Exception as e {
            report {"error": f"Invalid JSON: {e}"};
            disengage;
        }
        count = 0;
        for item in items {
            pid = str(uuid.uuid4());
            proj = Project(
                project_id=pid,
                name=item.get("name", ""),
                team_name=item.get("team_name", ""),
                track=item.get("track", ""),
                github_url=item.get("github_url", ""),
                demo_url=item.get("demo_url", ""),
                devpost_url=item.get("devpost_url", ""),
                description=item.get("description", "")
            );
            root +>:HasProject:+> proj;
            count += 1;
        }
        report {"imported": count};
    }
}

# ── Import Judges ──

walker:pub import_judges {
    has judges_json: str = "";

    can import_data with Root entry {
        try {
            items = json.loads(self.judges_json);
        } except Exception as e {
            report {"error": f"Invalid JSON: {e}"};
            disengage;
        }
        count = 0;
        for item in items {
            uid = str(uuid.uuid4());
            email = item.get("email", "");
            existing = find_profile_by_email(email);
            if existing != None {
                continue;
            }
            role = item.get("role", "judge");
            tracks_raw = item.get("assigned_tracks", "");
            if isinstance(tracks_raw, str) and tracks_raw {
                tracks = [t.strip() for t in tracks_raw.split(",")];
            } elif isinstance(tracks_raw, list) {
                tracks = tracks_raw;
            } else {
                tracks = [];
            }
            profile = UserProfile(
                user_id=uid,
                name=item.get("name", ""),
                email=email,
                role=role,
                assigned_tracks=tracks,
                sponsor_award_id=item.get("sponsor_award_id", "")
            );
            root +>:HasProfile:+> profile;
            count += 1;
        }
        report {"imported": count};
    }
}

# ── Get All Projects ──

walker:pub get_all_projects {
    can fetch with Root entry {
        projects = [root -->](?:Project);
        report [project_to_dict(p) for p in projects];
    }
}

# ── Get All Judges ──

walker:pub get_all_judges {
    can fetch with Root entry {
        profiles = [root -->](?:UserProfile);
        report [profile_to_dict(p) for p in profiles];
    }
}

# ── Assign Judges to Projects ──

walker:pub assign_judges {
    has email: str = "";
    has project_ids: list = [];

    can assign with Root entry {
        profile = find_profile_by_email(self.email);
        if profile == None {
            report {"error": "Judge not found"};
            disengage;
        }
        assigned = 0;
        for pid in self.project_ids {
            proj = find_project_by_id(pid);
            if proj != None {
                already = False;
                for existing in [profile -->](?:Project) {
                    if existing.project_id == pid {
                        already = True;
                    }
                }
                if not already {
                    profile +>:AssignedTo:+> proj;
                    assigned += 1;
                }
            }
        }
        report {"assigned": assigned, "judge": self.email};
    }
}

# ── Auto-Assign Judges ──

walker:pub auto_assign_judges {
    can assign with Root entry {
        judges = [p for p in [root -->](?:UserProfile) if p.role == "judge"];
        projects = [root -->](?:Project);
        assigned_count = 0;
        for proj in projects {
            for judge in judges {
                if proj.track in judge.assigned_tracks or len(judge.assigned_tracks) == 0 {
                    already = False;
                    for existing in [judge -->](?:Project) {
                        if existing.project_id == proj.project_id {
                            already = True;
                        }
                    }
                    if not already {
                        judge +>:AssignedTo:+> proj;
                        assigned_count += 1;
                    }
                }
            }
        }
        report {"total_assignments": assigned_count};
    }
}

# ── Get Assigned Projects (for Judge) ──

"""
Everything this judge must score right now, in table order, with their own
progress on each. Assignments are swapped wholesale when the final is built, so
whatever is attached to the judge is always the active round's worklist.
"""
walker:pub get_assigned_projects {
    has email: str = "";
    has round_num: int = 0;

    can fetch with Root entry {
        profile = find_profile_by_email(self.email);
        if profile == None {
            report {"error": "Profile not found"};
            disengage;
        }
        config = get_config_node();
        rnd = self.round_num if self.round_num > 0 else max(config.current_round, 1);

        assigned = [profile -->](?:Project);
        assigned.sort(key=lambda p: Project: (p.group_num, p.table_num));
        result = [];
        submitted = 0;
        for proj in assigned {
            my_score = None;
            for s in [proj -->](?:Score) {
                if s.judge_id == profile.user_id and s.round_num == rnd {
                    my_score = s;
                }
            }
            status = "not_started";
            if my_score != None {
                status = "submitted" if my_score.is_final else "in_progress";
            }
            if status == "submitted" {
                submitted += 1;
            }
            entry = project_to_dict(proj);
            entry["status"] = status;
            entry["round_num"] = rnd;
            entry["my_score"] = score_to_dict(my_score) if my_score != None else None;
            result.append(entry);
        }
        report {
            "round_num": rnd,
            "group_num": assigned[0].group_num if len(assigned) > 0 else 0,
            "scoring_locked": config.scoring_locked,
            "total": len(result),
            "submitted": submitted,
            "projects": result
        };
    }
}

# ── Get Project Detail ──

walker:pub get_project_detail {
    has project_id: str = "";
    has email: str = "";
    has round_num: int = 0;

    can fetch with Root entry {
        proj = find_project_by_id(self.project_id);
        if proj == None {
            report {"error": "Project not found"};
            disengage;
        }
        config = get_config_node();
        rnd = self.round_num if self.round_num > 0 else max(config.current_round, 1);
        profile = find_profile_by_email(self.email);
        result = project_to_dict(proj);
        result["scoring_locked"] = config.scoring_locked;
        result["round_num"] = rnd;
        scores = [proj -->](?:Score);
        # Scope to the active round so a submitted round-1 score never blocks or
        # pre-fills the judge's round-2 form.
        if profile != None {
            for s in scores {
                if s.judge_id == profile.user_id and s.round_num == rnd {
                    result["my_score"] = score_to_dict(s);
                }
            }
        }
        result["total_scores"] = len([
            s for s in scores if s.is_final and s.round_num == rnd
        ]);
        report result;
    }
}

# ── Save Score ──

walker:pub save_score {
    has email: str = "";
    has project_id: str = "";
    has technical_execution: int = 0;
    has jac_usage: int = 0;
    has creativity: int = 0;
    has presentation: int = 0;
    has notes: str = "";
    has is_final: bool = False;
    has round_num: int = 0;

    can save with Root entry {
        config = get_config_node();
        if config.scoring_locked {
            report {"error": "Scoring is locked"};
            disengage;
        }
        # Fall back to the active round so a stale client can never write a
        # round-2 score onto the round-1 record.
        if self.round_num <= 0 {
            self.round_num = max(config.current_round, 1);
        }
        profile = find_profile_by_email(self.email);
        if profile == None {
            report {"error": "Profile not found"};
            disengage;
        }
        proj = find_project_by_id(self.project_id);
        if proj == None {
            report {"error": "Project not found"};
            disengage;
        }
        existing_score: Score | None = None;
        for s in [proj -->](?:Score) {
            if s.judge_id == profile.user_id and s.round_num == self.round_num {
                existing_score = s;
            }
        }
        if existing_score != None {
            if existing_score.is_final {
                report {"error": "Score already submitted as final"};
                disengage;
            }
            existing_score.technical_execution = self.technical_execution;
            existing_score.jac_usage = self.jac_usage;
            existing_score.creativity = self.creativity;
            existing_score.presentation = self.presentation;
            existing_score.notes = self.notes;
            existing_score.is_final = self.is_final;
            existing_score.updated_at = datetime.now().isoformat();
            report score_to_dict(existing_score);
        } else {
            new_score = Score(
                score_id=str(uuid.uuid4()),
                judge_id=profile.user_id,
                project_id=self.project_id,
                technical_execution=self.technical_execution,
                jac_usage=self.jac_usage,
                creativity=self.creativity,
                presentation=self.presentation,
                notes=self.notes,
                is_final=self.is_final,
                round_num=self.round_num,
                updated_at=datetime.now().isoformat()
            );
            proj +>:HasScore:+> new_score;
            report score_to_dict(new_score);
        }
    }
}

# ── Get My Scores ──

walker:pub get_my_scores {
    has email: str = "";

    can fetch with Root entry {
        profile = find_profile_by_email(self.email);
        if profile == None {
            report {"error": "Profile not found"};
            disengage;
        }
        all_scores = [];
        for proj in [root -->](?:Project) {
            for s in [proj -->](?:Score) {
                if s.judge_id == profile.user_id {
                    entry = score_to_dict(s);
                    entry["project_name"] = proj.name;
                    all_scores.append(entry);
                }
            }
        }
        report all_scores;
    }
}

# ── Get Leaderboard ──

walker:pub get_leaderboard {
    has track: str = "";
    has round_num: int = 1;
    has sort_by: str = "normalized";

    can compute with Root entry {
        # Round 2 has every judge scoring every finalist, so raw averages are
        # already comparable and normalization only adds noise.
        finalists_only = self.round_num == 2;
        sort_by = "raw" if self.round_num == 2 else self.sort_by;
        result = build_rankings(self.round_num, finalists_only, sort_by);
        if self.track {
            result = [r for r in result if r["track"] == self.track];
        }
        report result;
    }
}

# ── Finalist Selection (Round 1 → Round 2) ──

"""
Close round 1 and build the final: take the top `per_track` projects in each
track, flag them as finalists, and assign EVERY judge to score all of them in
round 2. Because all judges see all finalists, round-2 scores need no
normalization and rank directly.
"""
walker:pub select_finalists {
    has per_track: int = 2;
    has sort_by: str = "normalized";

    can run with Root entry {
        judges = [p for p in [root -->](?:UserProfile) if p.role == "judge"];
        if len(judges) == 0 {
            report {"error": "No judges available"};
            disengage;
        }
        if self.per_track < 1 {
            self.per_track = 1;
        }

        ranked = build_rankings(1, False, self.sort_by);
        chosen = [];
        for entry in ranked {
            for e in entry["rankings"] {
                if e["rank"] <= self.per_track and e["num_judges"] > 0 {
                    chosen.append(e);
                }
            }
        }
        if len(chosen) == 0 {
            report {"error": "No scored projects in round 1 yet"};
            disengage;
        }

        # Reset any previous selection, then flag the new finalists.
        for p in [root -->](?:Project) {
            p.is_finalist = False;
            p.finalist_rank = 0;
        }
        chosen_ids = [];
        for e in chosen {
            proj = find_project_by_id(e["project_id"]);
            if proj != None {
                proj.is_finalist = True;
                proj.finalist_rank = e["rank"];
                chosen_ids.append(proj.project_id);
            }
        }

        # Rebuild assignments: every judge scores every finalist in round 2.
        finalists = [p for p in [root -->](?:Project) if p.is_finalist];
        finalists.sort(key=lambda p: Project: (p.track, p.finalist_rank));
        assignments = 0;
        for judge in judges {
            for proj in [judge -->](?:Project) {
                judge del --> proj;
            }
            for proj in finalists {
                judge +>:AssignedTo(round_num=2):+> proj;
                assignments += 1;
            }
        }

        config = get_config_node();
        config.finals_selected = True;
        config.finalists_per_track = self.per_track;
        config.current_round = 2;
        config.current_group = 0;

        report {
            "per_track": self.per_track,
            "finalists": [
                {
                    "project_id": p.project_id,
                    "name": p.name,
                    "team_name": p.team_name,
                    "track": p.track,
                    "round1_rank": p.finalist_rank
                }
                for p in finalists
            ],
            "total_finalists": len(finalists),
            "judges_assigned": len(judges),
            "assignments": assignments
        };
    }
}

"""Current finalists plus how many judges have submitted a round-2 score."""
walker:pub get_finalists {
    can fetch with Root entry {
        config = get_config_node();
        judges = [p for p in [root -->](?:UserProfile) if p.role == "judge"];
        finalists = [p for p in [root -->](?:Project) if p.is_finalist];
        finalists.sort(key=lambda p: Project: (p.track, p.finalist_rank));
        out = [];
        for p in finalists {
            scored = len([
                s for s in [p -->](?:Score)
                if s.round_num == 2 and s.is_final
            ]);
            entry = project_to_dict(p);
            entry["round2_scored_by"] = scored;
            entry["round2_pending"] = len(judges) - scored;
            out.append(entry);
        }
        report {
            "finals_selected": config.finals_selected,
            "per_track": config.finalists_per_track,
            "total_judges": len(judges),
            "finalists": out
        };
    }
}

"""Undo finalist selection and restore round-1 group assignments."""
walker:pub reset_finalists {
    can run with Root entry {
        for p in [root -->](?:Project) {
            p.is_finalist = False;
            p.finalist_rank = 0;
        }
        config = get_config_node();
        config.finals_selected = False;
        config.current_round = 1;
        report {"reset": True, "note": "Re-run Assign Judges to restore round 1"};
    }
}

# ── Get Progress ──

walker:pub get_progress {
    has round_num: int = 0;

    can compute with Root entry {
        config = get_config_node();
        rnd = self.round_num if self.round_num > 0 else max(config.current_round, 1);
        judges = [p for p in [root -->](?:UserProfile) if p.role == "judge"];
        projects = [root -->](?:Project);
        progress = [];
        total_expected = 0;
        total_submitted = 0;
        for judge in judges {
            assigned = [judge -->](?:Project);
            scored = 0;
            final_count = 0;
            group_num = assigned[0].group_num if len(assigned) > 0 else 0;
            for proj in assigned {
                for s in [proj -->](?:Score) {
                    if s.judge_id == judge.user_id and s.round_num == rnd {
                        scored += 1;
                        if s.is_final {
                            final_count += 1;
                        }
                    }
                }
            }
            total_expected += len(assigned);
            total_submitted += final_count;
            progress.append({
                "judge_name": judge.name,
                "judge_email": judge.email,
                "group_num": group_num,
                "assigned": len(assigned),
                "scored": scored,
                "submitted": final_count,
                "remaining": len(assigned) - final_count,
                "done": final_count >= len(assigned) and len(assigned) > 0
            });
        }
        progress.sort(key=lambda j: dict: (j["group_num"], j["judge_name"]));
        # Projects nobody has finalised yet — the list the organizer chases.
        unscored = [];
        for p in projects {
            if rnd == 2 and not p.is_finalist {
                continue;
            }
            if p.group_num == 0 and rnd == 1 {
                continue;
            }
            n = len([s for s in [p -->](?:Score) if s.is_final and s.round_num == rnd]);
            if n == 0 {
                unscored.append({
                    "project_id": p.project_id,
                    "name": p.name,
                    "team_name": p.team_name,
                    "group_num": p.group_num,
                    "table_num": p.table_num
                });
            }
        }
        report {
            "round_num": rnd,
            "total_projects": len(projects),
            "total_judges": len(judges),
            "expected_scores": total_expected,
            "submitted_scores": total_submitted,
            "percent_complete": round(100.0 * total_submitted / total_expected, 1) if total_expected > 0 else 0.0,
            "unscored_projects": unscored,
            "judges": progress
        };
    }
}

# ── Lock Scoring ──

walker:pub lock_scoring {
    has locked: bool = False;

    can toggle with Root entry {
        config = get_config_node();
        config.scoring_locked = self.locked;
        report {"scoring_locked": config.scoring_locked};
    }
}

# ── Export Results ──

walker:pub export_results {
    has track: str = "";
    has round_num: int = 1;
    has sort_by: str = "normalized";

    can export with Root entry {
        finalists_only = self.round_num == 2;
        sort_by = "raw" if self.round_num == 2 else self.sort_by;
        ranked = build_rankings(self.round_num, finalists_only, sort_by);
        if self.track {
            ranked = [r for r in ranked if r["track"] == self.track];
        }

        prize_map = {
            "agentic_ai": ["$2,000", "$1,000"],
            "fintech_open": ["$1,500", "$800"],
            "social_impact": ["$1,500", "$800"]
        };
        result = [];
        for entry in ranked {
            t = entry["track"];
            prizes = prize_map.get(t, []);
            enriched = [];
            winners = [];
            for e in entry["rankings"] {
                proj = find_project_by_id(e["project_id"]);
                judge_scores = [];
                if proj != None {
                    for s in [proj -->](?:Score) {
                        if not s.is_final or s.round_num != self.round_num {
                            continue;
                        }
                        judge_profile = None;
                        for jp in [root -->](?:UserProfile) {
                            if jp.user_id == s.judge_id {
                                judge_profile = jp;
                            }
                        }
                        judge_scores.append({
                            "judge_name": judge_profile.name if judge_profile else "Unknown",
                            "judge_email": judge_profile.email if judge_profile else "",
                            "technical_execution": s.technical_execution,
                            "jac_usage": s.jac_usage,
                            "creativity": s.creativity,
                            "presentation": s.presentation,
                            "weighted": round(compute_weighted_score(s), 2),
                            "notes": s.notes
                        });
                    }
                }
                row = dict(e);
                row["judge_scores"] = judge_scores;
                # Prizes only mean anything once the final has been scored.
                row["prize"] = prizes[e["rank"] - 1] if (
                    self.round_num == 2 and e["rank"] <= len(prizes)
                ) else "";
                enriched.append(row);
                winners.append({
                    "rank": e["rank"],
                    "project": e["name"],
                    "team": e["team_name"],
                    "score": e["avg_score"],
                    "norm_score": e["norm_score"],
                    "num_judges": e["num_judges"],
                    "prize": row["prize"],
                    "judge_scores": judge_scores
                });
            }
            # `rankings` for the UI table, `winners` kept for existing consumers.
            result.append({"track": t, "rankings": enriched, "winners": winners});
        }
        # Awards
        awards_result = [];
        for a in [root -->](?:SpecialAward) {
            winner_name = "";
            if a.winner_project_id {
                wp = find_project_by_id(a.winner_project_id);
                if wp != None {
                    winner_name = wp.name;
                }
            }
            awards_result.append({
                "award": a.name,
                "sponsor": a.sponsor,
                "prize": a.prize_description,
                "winner_project": winner_name,
                "winner_project_id": a.winner_project_id
            });
        }
        report {
            "round_num": self.round_num,
            "tracks": result,
            "special_awards": awards_result
        };
    }
}

# ── Create Award ──

walker:pub create_award {
    has name: str = "";
    has sponsor: str = "";
    has prize_description: str = "";

    can create with Root entry {
        aid = str(uuid.uuid4());
        award = SpecialAward(
            award_id=aid,
            name=self.name,
            sponsor=self.sponsor,
            prize_description=self.prize_description
        );
        root +>:HasAward:+> award;
        report award_to_dict(award);
    }
}

# ── Get Awards ──

walker:pub get_awards {
    can fetch with Root entry {
        awards = [root -->](?:SpecialAward);
        report [award_to_dict(a) for a in awards];
    }
}

# ── Set Award Winner ──

walker:pub set_award_winner {
    has award_id: str = "";
    has project_id: str = "";

    can assign with Root entry {
        award = find_award_by_id(self.award_id);
        if award == None {
            report {"error": "Award not found"};
            disengage;
        }
        proj = find_project_by_id(self.project_id);
        if proj == None {
            report {"error": "Project not found"};
            disengage;
        }
        award.winner_project_id = self.project_id;
        report award_to_dict(award);
    }
}

# ── Get Award Projects (for Sponsor Rep) ──

walker:pub get_award_projects {
    has email: str = "";

    can fetch with Root entry {
        profile = find_profile_by_email(self.email);
        if profile == None {
            report {"error": "Profile not found"};
            disengage;
        }
        award = find_award_by_id(profile.sponsor_award_id);
        if award == None {
            report {"error": "No award assigned"};
            disengage;
        }
        projects = [root -->](?:Project);
        result = [];
        for proj in projects {
            my_award_score = None;
            for as_ in [award -->](?:AwardScore) {
                if as_.project_id == proj.project_id and as_.judge_id == profile.user_id {
                    my_award_score = as_;
                }
            }
            entry = project_to_dict(proj);
            entry["award_name"] = award.name;
            entry["award_id"] = award.award_id;
            if my_award_score != None {
                entry["my_score"] = my_award_score.score;
                entry["my_notes"] = my_award_score.notes;
                entry["is_final"] = my_award_score.is_final;
                entry["status"] = "submitted" if my_award_score.is_final else "in_progress";
            } else {
                entry["my_score"] = None;
                entry["my_notes"] = "";
                entry["is_final"] = False;
                entry["status"] = "not_started";
            }
            result.append(entry);
        }
        report result;
    }
}

# ── Save Award Score ──

walker:pub save_award_score {
    has email: str = "";
    has award_id: str = "";
    has project_id: str = "";
    has score: float = 0.0;
    has notes: str = "";
    has is_final: bool = False;

    can save with Root entry {
        config = get_config_node();
        if config.scoring_locked {
            report {"error": "Scoring is locked"};
            disengage;
        }
        profile = find_profile_by_email(self.email);
        if profile == None {
            report {"error": "Profile not found"};
            disengage;
        }
        award = find_award_by_id(self.award_id);
        if award == None {
            report {"error": "Award not found"};
            disengage;
        }
        existing: AwardScore | None = None;
        for as_ in [award -->](?:AwardScore) {
            if as_.project_id == self.project_id and as_.judge_id == profile.user_id {
                existing = as_;
            }
        }
        if existing != None {
            if existing.is_final {
                report {"error": "Score already submitted as final"};
                disengage;
            }
            existing.score = self.score;
            existing.notes = self.notes;
            existing.is_final = self.is_final;
            report {
                "award_id": self.award_id,
                "project_id": self.project_id,
                "score": existing.score,
                "is_final": existing.is_final
            };
        } else {
            new_as = AwardScore(
                award_score_id=str(uuid.uuid4()),
                judge_id=profile.user_id,
                award_id=self.award_id,
                project_id=self.project_id,
                score=self.score,
                notes=self.notes,
                is_final=self.is_final
            );
            award +>:HasAwardScore:+> new_as;
            report {
                "award_id": self.award_id,
                "project_id": self.project_id,
                "score": new_as.score,
                "is_final": new_as.is_final
            };
        }
    }
}

# ── Delete Project ──

walker:pub delete_project {
    has project_id: str = "";

    can remove with Root entry {
        proj = find_project_by_id(self.project_id);
        if proj == None {
            report {"error": "Project not found"};
            disengage;
        }
        for s in [proj -->](?:Score) {
            del s;
        }
        del proj;
        report {"deleted": self.project_id};
    }
}

# ── Participant: Submit Project ──

walker:pub submit_project {
    has email: str = "";
    has name: str = "";
    has team_name: str = "";
    has track: str = "";
    has github_url: str = "";
    has demo_url: str = "";
    has devpost_url: str = "";
    has description: str = "";

    can submit with Root entry {
        profile = find_profile_by_email(self.email);
        if profile == None {
            report {"error": "Profile not found. Please register first."};
            disengage;
        }
        # Check if this team already submitted
        for p in [root -->](?:Project) {
            if p.team_name.lower() == self.team_name.strip().lower() {
                report {"error": f"Team '{self.team_name}' already has a submission. Use edit to update."};
                disengage;
            }
        }
        if not self.name.strip() or not self.team_name.strip() or not self.track.strip() {
            report {"error": "Project name, team name, and track are required."};
            disengage;
        }
        valid_tracks = ["agentic_ai", "fintech_open", "social_impact"];
        if self.track not in valid_tracks {
            report {"error": f"Track must be one of: {', '.join(valid_tracks)}"};
            disengage;
        }
        pid = str(uuid.uuid4());
        proj = Project(
            project_id=pid,
            name=self.name.strip(),
            team_name=self.team_name.strip(),
            track=self.track,
            github_url=self.github_url.strip(),
            demo_url=self.demo_url.strip(),
            devpost_url=self.devpost_url.strip(),
            description=self.description.strip(),
            submitted_by=self.email,
            submitted_at=datetime.now().isoformat()
        );
        root +>:HasProject:+> proj;
        report project_to_dict(proj);
    }
}

# ── Participant: Edit Project ──

walker:pub edit_project {
    has email: str = "";
    has project_id: str = "";
    has name: str = "";
    has team_name: str = "";
    has track: str = "";
    has github_url: str = "";
    has demo_url: str = "";
    has devpost_url: str = "";
    has description: str = "";

    can edit with Root entry {
        proj = find_project_by_id(self.project_id);
        if proj == None {
            report {"error": "Project not found"};
            disengage;
        }
        if proj.submitted_by != self.email {
            report {"error": "Only the original submitter can edit this project."};
            disengage;
        }
        config = get_config_node();
        if config.scoring_locked {
            report {"error": "Submissions are locked."};
            disengage;
        }
        if self.name.strip() {
            proj.name = self.name.strip();
        }
        if self.team_name.strip() {
            proj.team_name = self.team_name.strip();
        }
        if self.track.strip() {
            valid_tracks = ["agentic_ai", "fintech_open", "social_impact"];
            if self.track in valid_tracks {
                proj.track = self.track;
            }
        }
        if self.github_url.strip() {
            proj.github_url = self.github_url.strip();
        }
        if self.demo_url.strip() {
            proj.demo_url = self.demo_url.strip();
        }
        if self.devpost_url.strip() {
            proj.devpost_url = self.devpost_url.strip();
        }
        if self.description.strip() {
            proj.description = self.description.strip();
        }
        report project_to_dict(proj);
    }
}

# ── Participant: Get My Project ──

walker:pub get_my_project {
    has email: str = "";

    can fetch with Root entry {
        for p in [root -->](?:Project) {
            if p.submitted_by == self.email {
                report project_to_dict(p);
                disengage;
            }
        }
        report {"not_found": True};
    }
}

# ── Self-Register (participant signs up and gets a profile) ──

walker:pub register_participant {
    has email: str = "";
    has name: str = "";

    can register with Root entry {
        existing = find_profile_by_email(self.email);
        if existing != None {
            report profile_to_dict(existing);
            disengage;
        }
        uid = str(uuid.uuid4());
        profile = UserProfile(
            user_id=uid,
            name=self.name.strip(),
            email=self.email,
            role="participant",
            assigned_tracks=[],
            sponsor_award_id=""
        );
        root +>:HasProfile:+> profile;
        report profile_to_dict(profile);
    }
}

# ── Graph initialization ──

# ── Create Groups (split projects into groups of N) ──

"""
Split `num_groups` between tracks so the LARGEST group is as small as possible.

Every group is demoed back to back inside one fixed window, so the slot length
is dictated by the biggest group. Allocating proportionally to submission count
does not minimise that, so instead we hand each spare group to whichever track
currently has the worst largest-group, which does. Each track starts at
`min_per_track` groups so it can always field enough finalists.
Returns {track: group_count}.
"""
def allocate_groups_by_track(counts: dict, num_groups: int, min_per_track: int) -> dict {
    tracks = [t for t in counts.keys() if counts[t] > 0];
    tracks.sort();
    if len(tracks) == 0 {
        return {};
    }
    alloc: dict = {};
    floor_each = min_per_track;
    # If the floor cannot fit, back it off until it does (at least 1 each).
    while len(tracks) * floor_each > num_groups and floor_each > 1 {
        floor_each -= 1;
    }
    for t in tracks {
        alloc[t] = min(floor_each, counts[t]);
        if alloc[t] < 1 {
            alloc[t] = 1;
        }
    }
    # Hand each remaining group to the track whose largest group is worst,
    # which is exactly the greedy step that minimises the global maximum.
    used = sum([alloc[t] for t in tracks]);
    for _ in range(num_groups - used) {
        worst = None;
        worst_size = 0;
        for t in tracks {
            if alloc[t] >= counts[t] {
                continue;  # already one project per group, cannot improve
            }
            largest = -(-counts[t] // alloc[t]);  # ceil division
            if largest > worst_size {
                worst_size = largest;
                worst = t;
            }
        }
        if worst == None {
            break;
        }
        alloc[worst] += 1;
    }
    return alloc;
}

walker:pub create_groups {
    has num_groups: int = 10;
    has min_groups_per_track: int = 2;

    can create with Root entry {
        import random;
        projects = [root -->](?:Project);
        if len(projects) == 0 {
            report {"error": "No projects imported yet"};
            disengage;
        }
        if self.num_groups < 1 {
            self.num_groups = 1;
        }

        # Bucket by track. Groups are track-pure: a judge pair only ever compares
        # projects within one track, and every track is guaranteed its own
        # groups, so the finalist pool covers all three tracks by construction.
        by_track: dict = {};
        for p in projects {
            t = p.track if p.track else "fintech_open";
            if t not in by_track {
                by_track[t] = [];
            }
            by_track[t].append(p);
        }
        counts: dict = {};
        for (t, plist) in by_track.items() {
            counts[t] = len(plist);
        }
        alloc = allocate_groups_by_track(counts, self.num_groups, self.min_groups_per_track);

        # Clear any previous grouping so re-running is safe.
        for p in projects {
            p.group_num = 0;
            p.table_num = 0;
        }

        group_num = 0;
        groups_detail = [];
        track_summary = [];
        for t in sorted(alloc.keys()) {
            plist = by_track[t];
            random.shuffle(plist);
            n_groups = alloc[t];
            buckets = [[] for _ in range(n_groups)];
            # Deal round-robin so group sizes differ by at most one.
            for (i, p) in enumerate(plist) {
                buckets[i % n_groups].append(p);
            }
            track_summary.append({
                "track": t,
                "projects": len(plist),
                "groups": n_groups
            });
            for bucket in buckets {
                group_num += 1;
                entries = [];
                for (idx, p) in enumerate(bucket) {
                    p.group_num = group_num;
                    p.table_num = idx + 1;
                    entries.append({
                        "project_id": p.project_id,
                        "name": p.name,
                        "team_name": p.team_name,
                        "table_num": p.table_num
                    });
                }
                groups_detail.append({
                    "group_num": group_num,
                    "track": t,
                    "count": len(bucket),
                    "projects": entries
                });
            }
        }

        config = get_config_node();
        config.total_groups = group_num;
        config.group_size = self.num_groups;
        config.current_group = 0;
        config.current_round = 0;

        sizes = [grp["count"] for grp in groups_detail];
        report {
            "total_groups": group_num,
            "total_projects": len(projects),
            # The biggest group sets the demo slot length for the whole room.
            "max_group_size": max(sizes) if len(sizes) > 0 else 0,
            "min_group_size": min(sizes) if len(sizes) > 0 else 0,
            "by_track": track_summary,
            "groups": groups_detail
        };
    }
}

# ── Get Team Table (public, no login needed) ──

walker:pub get_team_tables {
    can fetch with Root entry {
        config = get_config_node();
        projects = [root -->](?:Project);
        groups_map: dict = {};
        for proj in projects {
            g = proj.group_num;
            if g not in groups_map {
                groups_map[g] = [];
            }
            groups_map[g].append({
                "name": proj.name,
                "team_name": proj.team_name,
                "table_num": proj.table_num,
                "group_num": g,
                "track": proj.track
            });
        }
        result = [];
        for (g, projs) in groups_map.items() {
            projs.sort(key=lambda x: dict: x["table_num"]);
            result.append({"group_num": g, "projects": projs});
        }
        result.sort(key=lambda x: dict: x["group_num"]);
        report {
            "groups": result,
            "current_group": config.current_group,
            "current_round": config.current_round,
            "total_groups": config.total_groups
        };
    }
}

# ── Get Groups (view all groups with table assignments) ──

walker:pub get_groups {
    can fetch with Root entry {
        projects = [root -->](?:Project);
        groups_map: dict = {};
        for proj in projects {
            g = str(proj.group_num);
            if g not in groups_map {
                groups_map[g] = [];
            }
            groups_map[g].append({
                "name": proj.name,
                "team_name": proj.team_name,
                "table_num": proj.table_num,
                "project_id": proj.project_id,
                "track": proj.track
            });
        }
        result = [];
        for (g, projs) in groups_map.items() {
            projs.sort(key=lambda x: dict: x["table_num"]);
            result.append({"group_num": int(g), "projects": projs});
        }
        result.sort(key=lambda x: dict: x["group_num"]);
        report result;
    }
}

# ── Rotation Assignment (assign each judge 2 projects per group) ──

"""
Pin each judge to exactly one group for round 1 and assign them every project in
it. Judges are dealt round-robin across groups, so with 20 judges and 10 groups
each group gets a pair; with fewer judges the groups differ by at most one.
Judges whose profile lists tracks are seated on a matching group where possible.
"""
walker:pub assign_rotation {
    can assign with Root entry {
        judges = [p for p in [root -->](?:UserProfile) if p.role == "judge"];
        projects = [root -->](?:Project);

        if len(judges) == 0 {
            report {"error": "No judges added yet"};
            disengage;
        }

        # Clear every existing assignment so re-running is safe.
        for judge in judges {
            for proj in [judge -->](?:Project) {
                judge del --> proj;
            }
        }

        groups: dict = {};
        for proj in projects {
            if proj.group_num == 0 {
                continue;
            }
            if proj.group_num not in groups {
                groups[proj.group_num] = [];
            }
            groups[proj.group_num].append(proj);
        }
        group_keys = sorted(groups.keys());
        if len(group_keys) == 0 {
            report {"error": "Run Create Groups first"};
            disengage;
        }

        group_track: dict = {};
        for g in group_keys {
            group_track[g] = groups[g][0].track;
        }

        # Seat track-specialist judges first so they land on a matching group,
        # then fill the rest, each time picking the emptiest eligible group so
        # sizes stay even.
        per_group: dict = {};
        for g in group_keys {
            per_group[g] = [];
        }
        ordered = [j for j in judges if len(j.assigned_tracks) > 0];
        ordered += [j for j in judges if len(j.assigned_tracks) == 0];

        for judge in ordered {
            candidates = group_keys;
            if len(judge.assigned_tracks) > 0 {
                matching = [g for g in group_keys if group_track[g] in judge.assigned_tracks];
                if len(matching) > 0 {
                    candidates = matching;
                }
            }
            target = candidates[0];
            for g in candidates {
                if len(per_group[g]) < len(per_group[target]) {
                    target = g;
                }
            }
            per_group[target].append(judge);
        }

        total_assignments = 0;
        detail = [];
        for g in group_keys {
            group_projects = groups[g];
            group_projects.sort(key=lambda p: Project: p.table_num);
            for judge in per_group[g] {
                for proj in group_projects {
                    judge +>:AssignedTo(round_num=1):+> proj;
                    total_assignments += 1;
                }
            }
            detail.append({
                "group_num": g,
                "track": group_track[g],
                "projects": len(group_projects),
                "judges": [{"name": j.name, "email": j.email} for j in per_group[g]]
            });
        }

        unstaffed = [g for g in group_keys if len(per_group[g]) == 0];
        report {
            "total_assignments": total_assignments,
            "judges": len(judges),
            "groups": len(group_keys),
            "projects_per_judge": round(total_assignments / len(judges), 1),
            "unstaffed_groups": unstaffed,
            "assignments": detail
        };
    }
}

# ── Set Current Group/Round (organizer controls) ──

walker:pub set_judging_state {
    has current_group: int = 0;
    has current_round: int = 0;

    can set with Root entry {
        config = get_config_node();
        config.current_group = self.current_group;
        config.current_round = self.current_round;
        report {
            "current_group": config.current_group,
            "current_round": config.current_round
        };
    }
}

# ── Get Judge's Current Assignment ──

walker:pub get_current_assignment {
    has email: str = "";

    can fetch with Root entry {
        profile = find_profile_by_email(self.email);
        if profile == None {
            report {"error": "Profile not found"};
            disengage;
        }
        config = get_config_node();
        current_group = config.current_group;
        current_round = config.current_round;

        # Get all assigned projects, group by group_num, sort by table_num
        assigned = [profile -->](?:Project);
        # Group by group_num first
        by_group: dict = {};
        for proj in assigned {
            g = proj.group_num;
            if g not in by_group {
                by_group[g] = [];
            }
            by_group[g].append(proj);
        }
        # Sort each group by table_num so lower table = Round 1, higher = Round 2
        all_assignments = [];
        for (g, projs) in by_group.items() {
            projs.sort(key=lambda p: Project: p.table_num);
            for (idx, proj) in enumerate(projs) {
                round_num = idx + 1;
                all_assignments.append({
                    "project": project_to_dict(proj),
                    "round_num": round_num,
                    "group_num": g
                });
            }
        }

        # Find current assignment
        current = None;
        for a in all_assignments {
            if a["group_num"] == current_group and a["round_num"] == current_round {
                current = a;
            }
        }

        report {
            "current_group": current_group,
            "current_round": current_round,
            "current_assignment": current,
            "all_assignments": all_assignments,
            "total_groups": config.total_groups
        };
    }
}

# ── Update Role ──

walker:pub update_role {
    has email: str = "";
    has role: str = "";

    can update with Root entry {
        profile = find_profile_by_email(self.email);
        if profile == None {
            report {"error": "Profile not found"};
            disengage;
        }
        profile.role = self.role;
        report {"email": profile.email, "role": profile.role};
    }
}

# ── Delete Judge ──

walker:pub delete_judge {
    has email: str = "";

    can remove with Root entry {
        profile = find_profile_by_email(self.email);
        if profile == None {
            report {"error": "Judge not found"};
            disengage;
        }
        # Remove all assignment edges
        for proj in [profile -->](?:Project) {
            profile del --> proj;
        }
        del profile;
        report {"deleted": self.email};
    }
}

# ── Send Judge Invite Email ──

walker:pub send_invite_email {
    has to_email: str = "";
    has to_name: str = "";
    has password: str = "jachacks2026";
    has platform_url: str = "https://jachacks.org/judging";
    has schedule_url: str = "https://jachacks.org/schedule";

    can send with Root entry {
        import os;
        import smtplib;
        import from email.mime.text { MIMEText }
        import from email.mime.multipart { MIMEMultipart }

        smtp_email = os.getenv("SMTP_EMAIL", "");
        smtp_password = os.getenv("SMTP_PASSWORD", "");

        if not smtp_email or not smtp_password {
            report {"error": "SMTP not configured. Set SMTP_EMAIL and SMTP_PASSWORD env vars."};
            disengage;
        }

        subject = "You're Invited to Judge at JacHacks 2026! 🎉";
        html_body = f"""
        <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; max-width: 560px; margin: 0 auto; background: #0d0d0d; color: #e8e8e8; border-radius: 16px; overflow: hidden;">
            <div style="height: 4px; background: linear-gradient(90deg, #F4622A, #FF8C5A, #F4622A);"></div>
            <div style="padding: 40px 36px;">
                <h1 style="color: #F4622A; margin: 0 0 4px 0; font-size: 32px; font-weight: 800;">JacHacks <span style="color: #fff;">2026</span></h1>
                <p style="color: #666; margin: 0 0 32px 0; font-size: 13px; letter-spacing: 1px; text-transform: uppercase;">Ann Arbor's Premier AI Hackathon</p>

                <p style="font-size: 16px; line-height: 1.6; margin-bottom: 16px;">Hi {self.to_name},</p>

                <p style="font-size: 16px; line-height: 1.6; margin-bottom: 16px;">We're thrilled to have you on board as a <strong style="color: #F4622A;">judge</strong> for JacHacks 2026! Your expertise and perspective will play a vital role in evaluating the incredible projects our hackers are building this weekend.</p>

                <p style="font-size: 16px; line-height: 1.6; margin-bottom: 24px;">We've created a judging account for you on our platform. Here are your login credentials:</p>

                <div style="background: linear-gradient(135deg, #1a1a1a, #1f1a15); border: 1px solid #2a2a2a; border-left: 3px solid #F4622A; border-radius: 10px; padding: 20px 24px; margin: 0 0 28px 0;">
                    <p style="margin: 6px 0; font-size: 15px;"><span style="color: #888;">Platform:</span> <a href="{self.platform_url}" style="color: #F4622A; font-weight: 600;">{self.platform_url}</a></p>
                    <p style="margin: 6px 0; font-size: 15px;"><span style="color: #888;">Email:</span> <strong>{self.to_email}</strong></p>
                    <p style="margin: 6px 0; font-size: 15px;"><span style="color: #888;">Password:</span> <code style="background: #2a2a2a; padding: 2px 8px; border-radius: 4px; font-family: monospace; color: #F4622A;">{self.password}</code></p>
                </div>

                <div style="background: #1a1a1a; border: 1px solid #2a2a2a; border-radius: 10px; padding: 20px 24px; margin-bottom: 28px;">
                    <p style="font-weight: 700; color: #fff; margin: 0 0 8px 0; font-size: 14px; text-transform: uppercase; letter-spacing: 0.5px;">📅 Schedule</p>
                    <p style="margin: 4px 0; font-size: 14px; color: #ccc;">Please arrive at the venue by <strong style="color: #fff;">10:30 AM on Saturday, April 5</strong></p>
                    <p style="margin: 4px 0; font-size: 14px; color: #ccc;">We'll hold a <strong style="color: #fff;">Judge Briefing</strong> before demos begin where we'll walk you through the process, the platform, and answer any questions</p>
                    <p style="margin: 8px 0 0 0; font-size: 13px; color: #888;">You're also welcome to stop by today (April 4) to see the hackers in action!</p>
                    <p style="margin: 8px 0 0 0; font-size: 13px;"><a href="{self.schedule_url}" style="color: #F4622A;">View the full event schedule</a></p>
                </div>

                <p style="font-size: 14px; line-height: 1.6; margin-bottom: 12px; color: #ccc;">During the demo session, you'll rate each project on <strong style="color: #fff;">4 criteria</strong> (1–5 stars, equally weighted):</p>

                <table style="width: 100%; border-collapse: collapse; margin-bottom: 28px;">
                    <tr>
                        <td style="padding: 8px 12px; border-bottom: 1px solid #2a2a2a; color: #F4622A; font-weight: 600; font-size: 14px;">⚡ Technical Execution</td>
                        <td style="padding: 8px 12px; border-bottom: 1px solid #2a2a2a; color: #888; font-size: 13px; text-align: right;">25%</td>
                    </tr>
                    <tr>
                        <td style="padding: 8px 12px; border-bottom: 1px solid #2a2a2a; color: #F4622A; font-weight: 600; font-size: 14px;">🔧 Use of Jac &amp; Jaseci</td>
                        <td style="padding: 8px 12px; border-bottom: 1px solid #2a2a2a; color: #888; font-size: 13px; text-align: right;">25%</td>
                    </tr>
                    <tr>
                        <td style="padding: 8px 12px; border-bottom: 1px solid #2a2a2a; color: #F4622A; font-weight: 600; font-size: 14px;">💡 Creativity &amp; Innovation</td>
                        <td style="padding: 8px 12px; border-bottom: 1px solid #2a2a2a; color: #888; font-size: 13px; text-align: right;">25%</td>
                    </tr>
                    <tr>
                        <td style="padding: 8px 12px; color: #F4622A; font-weight: 600; font-size: 14px;">🎤 Presentation &amp; Demo</td>
                        <td style="padding: 8px 12px; color: #888; font-size: 13px; text-align: right;">25%</td>
                    </tr>
                </table>

                <p style="font-size: 16px; line-height: 1.6; margin-bottom: 8px;">We're proud to have you lending your expertise to this event. The teams have been building all weekend and are excited to show you what they've created.</p>

                <p style="font-size: 16px; line-height: 1.6; margin-bottom: 28px;">See you there! 🚀</p>

                <div style="border-top: 1px solid #2a2a2a; padding-top: 20px;">
                    <p style="margin: 0; color: #F4622A; font-weight: 700; font-size: 14px;">The JacHacks Team</p>
                    <p style="margin: 4px 0 0 0; color: #666; font-size: 12px;">University of Michigan • Ann Arbor, MI</p>
                    <p style="margin: 4px 0 0 0; color: #666; font-size: 12px;">jachacks.org</p>
                </div>
            </div>
        </div>
        """;

        try {
            msg = MIMEMultipart("alternative");
            msg["Subject"] = subject;
            msg["From"] = smtp_email;
            msg["To"] = self.to_email;
            msg.attach(MIMEText(html_body, "html"));

            server = smtplib.SMTP_SSL("smtp.gmail.com", 465);
            server.login(smtp_email, smtp_password);
            server.sendmail(smtp_email, self.to_email, msg.as_string());
            server.quit();
            report {"sent": True, "to": self.to_email};
        } except Exception as e {
            report {"error": f"Failed to send: {e}"};
        }
    }
}

with entry {
    configs = [root -->](?:Config);
    if len(configs) == 0 {
        root +>:HasConfig:+> Config();
    }
}

# ── Client entry point ──

cl import from "@jac/runtime" {
    Router,
    Routes,
    Route,
    Link,
    useNavigate,
    useParams,
    jacLogin,
    jacSignup,
    jacLogout,
    jacIsLoggedIn
}

cl import from react { useEffect }

cl import "./styles/main.css";

sv import from main {
    get_profile,
    register_participant,
    get_my_project,
    submit_project,
    edit_project,
    get_assigned_projects,
    get_project_detail,
    save_score,
    get_leaderboard,
    get_progress,
    get_config,
    lock_scoring,
    import_projects,
    import_judges,
    auto_assign_judges,
    export_results
}


cl {
    # ── Login Page ──
    def LoginPage() -> JsxElement {
        has email: str = "";
        has password: str = "";
        has displayName: str = "";
        has error: str = "";
        has loading: bool = False;
        has isSignup: bool = False;

        navigate = useNavigate();

        can with entry {
            if jacIsLoggedIn() {
                role = localStorage.getItem("jachacks_role");
                if role == "judge" { navigate("/judge"); }
                elif role == "organizer" { navigate("/organizer"); }
                elif role == "sponsor_rep" { navigate("/sponsor"); }
                elif role == "participant" { navigate("/submit"); }
            }
        }

        async def handleSubmit(e: any) -> None {
            e.preventDefault();
            error = "";
            if not email.trim() or not password {
                error = "Please fill in all fields";
                return;
            }
            loading = True;
            if isSignup {
                if not displayName.trim() {
                    error = "Please enter your name";
                    loading = False;
                    return;
                }
                result = await jacSignup(email, password);
                if not result["success"] {
                    error = result.get("error", "Signup failed");
                    loading = False;
                    return;
                }
                # Auto-create participant profile
                try {
                    reg = root spawn register_participant(email=email, name=displayName.trim());
                    if reg.reports and reg.reports.length > 0 {
                        prof = reg.reports[0];
                        localStorage.setItem("jachacks_role", prof.get("role", "participant"));
                        localStorage.setItem("jachacks_email", email);
                        localStorage.setItem("jachacks_user_id", prof.get("user_id", ""));
                        localStorage.setItem("jachacks_name", prof.get("name", ""));
                        loading = False;
                        navigate("/submit");
                        return;
                    }
                } except Exception as ex {
                    error = f"Profile creation failed: {ex}";
                    loading = False;
                    return;
                }
            } else {
                success = await jacLogin(email, password);
                if not success {
                    error = "Invalid credentials";
                    loading = False;
                    return;
                }
            }
            # Fetch profile
            try {
                pr = root spawn get_profile(email=email);
                if pr.reports and pr.reports.length > 0 {
                    prof = pr.reports[0];
                    if prof.get("error") {
                        reg = root spawn register_participant(email=email, name=email.split("@")[0]);
                        if reg.reports and reg.reports.length > 0 {
                            prof = reg.reports[0];
                        }
                    }
                    role = prof.get("role", "participant");
                    localStorage.setItem("jachacks_role", role);
                    localStorage.setItem("jachacks_email", email);
                    localStorage.setItem("jachacks_user_id", prof.get("user_id", ""));
                    localStorage.setItem("jachacks_name", prof.get("name", ""));
                    loading = False;
                    if role == "judge" { navigate("/judge"); }
                    elif role == "organizer" { navigate("/organizer"); }
                    elif role == "sponsor_rep" { navigate("/sponsor"); }
                    else { navigate("/submit"); }
                    return;
                }
            } except Exception as ex {
                error = f"Login error: {ex}";
            }
            loading = False;
        }

        return <div className="login-container">
            <div className="login-card">
                <div className="login-title">
                    <span style={{"color": "var(--accent)"}}>JAC</span>HACKS
                </div>
                <div className="login-subtitle">Judging & Submissions Platform</div>
                <form onSubmit={handleSubmit}>
                    {error and <div className="alert alert-error">{error}</div>}
                    {isSignup and (
                        <div className="form-group">
                            <label className="form-label">Your Name</label>
                            <input type="text" className="form-input" value={displayName}
                                onChange={lambda e: any -> None { displayName = e.target.value; }}
                                placeholder="Jane Doe" />
                        </div>
                    )}
                    <div className="form-group">
                        <label className="form-label">Email</label>
                        <input type="text" className="form-input" value={email}
                            onChange={lambda e: any -> None { email = e.target.value; }}
                            placeholder="you@umich.edu" />
                    </div>
                    <div className="form-group">
                        <label className="form-label">Password</label>
                        <input type="password" className="form-input" value={password}
                            onChange={lambda e: any -> None { password = e.target.value; }}
                            placeholder="Password" />
                    </div>
                    <button type="submit" className="btn btn-primary btn-lg w-full" disabled={loading}>
                        {loading and "Loading..." or (isSignup and "Sign Up as Hacker" or "Login")}
                    </button>
                    <div style={{"textAlign": "center", "marginTop": "16px"}}>
                        <button type="button" className="text-sm"
                            style={{"background": "none", "border": "none", "color": "var(--accent)", "cursor": "pointer"}}
                            onClick={lambda -> None { isSignup = not isSignup; error = ""; }}>
                            {isSignup and "Already have an account? Login" or "New hacker? Sign up here"}
                        </button>
                    </div>
                </form>
            </div>
        </div>;
    }

    # ── Submit Project Page ──
    def SubmitPage() -> JsxElement {
        has projectName: str = "";
        has teamName: str = "";
        has track: str = "";
        has githubUrl: str = "";
        has demoUrl: str = "";
        has devpostUrl: str = "";
        has description: str = "";
        has loading: bool = True;
        has saving: bool = False;
        has error: str = "";
        has success: str = "";
        has isEdit: bool = False;
        has existingId: str = "";

        email = localStorage.getItem("jachacks_email") or "";

        async can with entry {
            try {
                result = root spawn get_my_project(email=email);
                if result.reports and result.reports.length > 0 {
                    d = result.reports[0];
                    if not d.get("not_found") and not d.get("error") {
                        isEdit = True;
                        existingId = d.get("project_id", "");
                        projectName = d.get("name", "");
                        teamName = d.get("team_name", "");
                        track = d.get("track", "");
                        githubUrl = d.get("github_url", "");
                        demoUrl = d.get("demo_url", "");
                        devpostUrl = d.get("devpost_url", "");
                        description = d.get("description", "");
                    }
                }
            } except Exception as ex { print(ex); }
            loading = False;
        }

        async def handleSubmit(e: any) -> None {
            e.preventDefault();
            error = "";
            success = "";
            saving = True;
            try {
                if isEdit {
                    r = root spawn edit_project(email=email, project_id=existingId,
                        name=projectName, team_name=teamName, track=track,
                        github_url=githubUrl, demo_url=demoUrl,
                        devpost_url=devpostUrl, description=description);
                } else {
                    r = root spawn submit_project(email=email,
                        name=projectName, team_name=teamName, track=track,
                        github_url=githubUrl, demo_url=demoUrl,
                        devpost_url=devpostUrl, description=description);
                }
                if r.reports and r.reports.length > 0 {
                    d = r.reports[0];
                    if d.get("error") { error = d["error"]; }
                    else {
                        isEdit = True;
                        existingId = d.get("project_id", "");
                        success = "Project saved!";
                    }
                }
            } except Exception as ex { error = f"Failed: {ex}"; }
            saving = False;
        }

        if loading { return <div className="text-muted">Loading...</div>; }

        return <div style={{"maxWidth": "640px", "margin": "0 auto"}}>
            <h1>{isEdit and "Edit Your Submission" or "Submit Your Project"}</h1>
            <p className="text-muted mt-2 mb-4">
                {isEdit and "Update your project details." or "One submission per team."}
            </p>
            {error and <div className="alert alert-error">{error}</div>}
            {success and <div className="alert alert-success">{success}</div>}
            <form onSubmit={handleSubmit}>
                <div className="card mb-4">
                    <div className="form-group">
                        <label className="form-label">Project Name *</label>
                        <input className="form-input" value={projectName} required={True}
                            onChange={lambda e: any -> None { projectName = e.target.value; }}
                            placeholder="My Awesome AI Project" />
                    </div>
                    <div className="form-group">
                        <label className="form-label">Team Name *</label>
                        <input className="form-input" value={teamName} required={True}
                            disabled={isEdit}
                            onChange={lambda e: any -> None { teamName = e.target.value; }}
                            placeholder="Team Rocket" />
                    </div>
                    <div className="form-group">
                        <label className="form-label">Track *</label>
                        <select className="form-select" value={track} required={True}
                            onChange={lambda e: any -> None { track = e.target.value; }}>
                            <option value="">Select a track...</option>
                            <option value="agentic_ai">Agentic AI</option>
                            <option value="fintech_open">Fintech / Open</option>
                            <option value="social_impact">Social Impact</option>
                        </select>
                    </div>
                    <div className="form-group">
                        <label className="form-label">Description</label>
                        <textarea className="form-textarea" value={description}
                            onChange={lambda e: any -> None { description = e.target.value; }}
                            placeholder="What does your project do?" />
                    </div>
                </div>
                <div className="card mb-4">
                    <h4 className="card-title mb-4">Links</h4>
                    <div className="form-group">
                        <label className="form-label">GitHub</label>
                        <input className="form-input" value={githubUrl}
                            onChange={lambda e: any -> None { githubUrl = e.target.value; }}
                            placeholder="https://github.com/..." />
                    </div>
                    <div className="form-group">
                        <label className="form-label">Demo URL</label>
                        <input className="form-input" value={demoUrl}
                            onChange={lambda e: any -> None { demoUrl = e.target.value; }}
                            placeholder="https://..." />
                    </div>
                    <div className="form-group">
                        <label className="form-label">Devpost</label>
                        <input className="form-input" value={devpostUrl}
                            onChange={lambda e: any -> None { devpostUrl = e.target.value; }}
                            placeholder="https://devpost.com/..." />
                    </div>
                </div>
                <button type="submit" className="btn btn-primary btn-lg w-full" disabled={saving}>
                    {saving and "Saving..." or (isEdit and "Update Project" or "Submit Project")}
                </button>
            </form>
        </div>;
    }

    # ── Judge Dashboard ──
    def JudgeDashboard() -> JsxElement {
        has projects: list = [];
        has loading: bool = True;
        has error: str = "";

        email = localStorage.getItem("jachacks_email") or "";
        name = localStorage.getItem("jachacks_name") or "Judge";

        async can with entry {
            try {
                r = root spawn get_assigned_projects(email=email);
                if r.reports and r.reports.length > 0 {
                    d = r.reports[0];
                    if Array.isArray(d) { projects = d; }
                    elif d.get and d.get("error") { error = d["error"]; }
                }
            } except Exception as ex { error = f"Failed: {ex}"; }
            loading = False;
        }

        if loading { return <div className="text-muted">Loading...</div>; }
        scored = len([p for p in projects if p.get("status") == "submitted"]);

        return <div>
            <h1>Welcome, {name}</h1>
            <p className="text-muted mt-2 mb-4">{scored}/{len(projects)} scored</p>
            {error and <div className="alert alert-error">{error}</div>}
            {len(projects) == 0 and not error and (
                <div className="card"><p className="text-muted">No projects assigned yet.</p></div>
            )}
            <div className="grid grid-2">
                {[<Link key={p["project_id"]} to={"/judge/" + p["project_id"]}
                    style={{"textDecoration": "none", "color": "inherit"}}>
                    <div className="card">
                        <div className="card-header">
                            <h4 className="card-title">{p.get("name", "")}</h4>
                            <span className={"chip chip-" + p.get("status", "not_started")}>
                                {p.get("status", "").replace("_", " ")}
                            </span>
                        </div>
                        <div className="flex items-center gap-2">
                            <span className="chip chip-track">{p.get("track", "").replace("_", " ").toUpperCase()}</span>
                            <span className="text-muted text-sm">{p.get("team_name", "")}</span>
                        </div>
                    </div>
                </Link> for p in projects]}
            </div>
        </div>;
    }

    # ── Judge Score Page ──
    def JudgeScorePage() -> JsxElement {
        has project: dict = {};
        has loading: bool = True;
        has error: str = "";
        has saved: str = "";
        has technical: float = 5.0;
        has jacUsage: float = 5.0;
        has creativity: float = 5.0;
        has impact: float = 5.0;
        has presentation: float = 5.0;
        has notes: str = "";
        has disabled: bool = False;
        has saving: bool = False;

        params = useParams();
        navigate = useNavigate();
        projectId = params.project_id;
        email = localStorage.getItem("jachacks_email") or "";

        async can with entry {
            try {
                r = root spawn get_project_detail(project_id=projectId, email=email);
                if r.reports and r.reports.length > 0 {
                    d = r.reports[0];
                    if d.get("error") { error = d["error"]; }
                    else {
                        project = d;
                        ms = d.get("my_score");
                        if ms {
                            technical = ms.get("technical_execution", 5.0);
                            jacUsage = ms.get("jac_usage", 5.0);
                            creativity = ms.get("creativity", 5.0);
                            impact = ms.get("impact", 5.0);
                            presentation = ms.get("presentation", 5.0);
                            notes = ms.get("notes", "");
                            if ms.get("is_final") { disabled = True; }
                        }
                        if d.get("scoring_locked") { disabled = True; }
                    }
                }
            } except Exception as ex { error = f"Failed: {ex}"; }
            loading = False;
        }

        async def handleSave(isFinal: bool) -> None {
            error = "";
            saved = "";
            saving = True;
            try {
                r = root spawn save_score(email=email, project_id=projectId,
                    technical_execution=technical, jac_usage=jacUsage,
                    creativity=creativity, impact=impact, presentation=presentation,
                    notes=notes, is_final=isFinal);
                if r.reports and r.reports.length > 0 {
                    d = r.reports[0];
                    if d.get("error") { error = d["error"]; }
                    else {
                        saved = isFinal and "Score submitted!" or "Draft saved!";
                        if isFinal { disabled = True; }
                    }
                }
            } except Exception as ex { error = f"Failed: {ex}"; }
            saving = False;
        }

        if loading { return <div className="text-muted">Loading...</div>; }

        weighted = technical * 0.30 + jacUsage * 0.25 + creativity * 0.20 + impact * 0.15 + presentation * 0.10;
        sliders = [
            {"label": "Technical Execution", "val": technical, "w": "30%",
             "set": lambda v: any -> None { technical = parseFloat(v); }},
            {"label": "JAC Usage", "val": jacUsage, "w": "25%",
             "set": lambda v: any -> None { jacUsage = parseFloat(v); }},
            {"label": "Creativity", "val": creativity, "w": "20%",
             "set": lambda v: any -> None { creativity = parseFloat(v); }},
            {"label": "Impact", "val": impact, "w": "15%",
             "set": lambda v: any -> None { impact = parseFloat(v); }},
            {"label": "Presentation", "val": presentation, "w": "10%",
             "set": lambda v: any -> None { presentation = parseFloat(v); }}
        ];

        return <div>
            <button className="btn btn-secondary btn-sm mb-4" onClick={lambda -> None { navigate("/judge"); }}>
                Back to projects
            </button>
            <h1>{project.get("name", "Project")}</h1>
            <div className="flex items-center gap-3 mt-2 mb-4">
                <span className="chip chip-track">{project.get("track", "").replace("_", " ").toUpperCase()}</span>
                <span className="text-muted">{project.get("team_name", "")}</span>
            </div>
            {project["description"] and <p className="text-muted mb-4">{project["description"]}</p>}
            <div className="flex gap-3 mb-4">
                {project["github_url"] and <a href={project["github_url"]} target="_blank">GitHub</a>}
                {project["demo_url"] and <a href={project["demo_url"]} target="_blank">Demo</a>}
                {project["devpost_url"] and <a href={project["devpost_url"]} target="_blank">Devpost</a>}
            </div>
            {disabled and <div className="alert alert-success">Score submitted (read-only).</div>}
            {error and <div className="alert alert-error">{error}</div>}
            {saved and <div className="alert alert-success">{saved}</div>}

            {[<div key={s["label"]} className="score-slider-container">
                <div className="score-slider-header">
                    <div>
                        <span className="score-slider-label">{s["label"]}</span>
                        <span className="score-slider-weight"> ({s["w"]})</span>
                    </div>
                    <span className="score-slider-value">{s["val"].toFixed(1)}</span>
                </div>
                <input type="range" className="score-slider" min="0" max="10" step="0.5"
                    value={s["val"]} disabled={disabled}
                    onChange={lambda e: any -> None { s["set"](e.target.value); }} />
            </div> for s in sliders]}

            <div className="card" style={{"margin": "16px 0", "textAlign": "center"}}>
                <div className="text-muted text-sm">WEIGHTED SCORE</div>
                <div className="score-slider-value" style={{"fontSize": "32px"}}>{weighted.toFixed(2)}</div>
            </div>
            <div className="form-group">
                <label className="form-label">Notes</label>
                <textarea className="form-textarea" value={notes} disabled={disabled}
                    placeholder="Optional notes..."
                    onChange={lambda e: any -> None { notes = e.target.value; }} />
            </div>
            {not disabled and (
                <div className="flex gap-3 mt-4">
                    <button className="btn btn-secondary" style={{"flex": "1"}} disabled={saving}
                        onClick={lambda -> None { handleSave(False); }}>
                        {saving and "Saving..." or "Save Draft"}
                    </button>
                    <button className="btn btn-primary" style={{"flex": "1"}} disabled={saving}
                        onClick={lambda -> None {
                            if window.confirm("Submit final score? This cannot be changed.") { handleSave(True); }
                        }}>Submit Final</button>
                </div>
            )}
        </div>;
    }

    # ── Organizer Dashboard ──
    def OrganizerDashboard() -> JsxElement {
        has leaderboard: list = [];
        has progress: dict = {};
        has config: dict = {};
        has loading: bool = True;
        has error: str = "";

        async def fetchData() -> None {
            try {
                lb = root spawn get_leaderboard(track="");
                if lb.reports and lb.reports.length > 0 { leaderboard = lb.reports[0]; }
                pg = root spawn get_progress();
                if pg.reports and pg.reports.length > 0 { progress = pg.reports[0]; }
                cf = root spawn get_config();
                if cf.reports and cf.reports.length > 0 { config = cf.reports[0]; }
            } except Exception as ex { error = f"Error: {ex}"; }
            loading = False;
        }

        async can with entry { await fetchData(); }
        useEffect(lambda -> None {
            iv = setInterval(lambda -> None { fetchData(); }, 5000);
            return lambda -> None { clearInterval(iv); };
        }, []);

        async def toggleLock() -> None {
            newVal = not config.get("scoring_locked", False);
            r = root spawn lock_scoring(locked=newVal);
            if r.reports and r.reports.length > 0 {
                config = {**config, "scoring_locked": r.reports[0].get("scoring_locked", False)};
            }
        }

        if loading { return <div className="text-muted">Loading dashboard...</div>; }
        locked = config.get("scoring_locked", False);
        judges = progress.get("judges", []);
        totalSub = sum([j.get("submitted", 0) for j in judges]);
        totalAsgn = sum([j.get("assigned", 0) for j in judges]);

        return <div>
            <div className="section-header">
                <h1>Mission Control</h1>
                <div className="flex gap-3">
                    <Link to="/organizer/import" className="btn btn-secondary">Import</Link>
                    <Link to="/organizer/results" className="btn btn-primary">Results</Link>
                </div>
            </div>
            {error and <div className="alert alert-error">{error}</div>}
            <div className="grid grid-4 mb-4" style={{"marginTop": "20px"}}>
                <div className="stat-card">
                    <div className="stat-value">{progress.get("total_projects", 0)}</div>
                    <div className="stat-label">Projects</div>
                </div>
                <div className="stat-card">
                    <div className="stat-value">{progress.get("total_judges", 0)}</div>
                    <div className="stat-label">Judges</div>
                </div>
                <div className="stat-card">
                    <div className="stat-value">{totalSub}/{totalAsgn}</div>
                    <div className="stat-label">Scores</div>
                </div>
                <div className="stat-card">
                    <div className="toggle-container" style={{"justifyContent": "center"}}>
                        <div className={"toggle" + (locked and " active" or "")}
                            onClick={lambda -> None { toggleLock(); }} />
                        <span style={{"fontSize": "12px", "color": locked and "var(--error)" or "var(--text-muted)"}}>
                            {locked and "LOCKED" or "OPEN"}
                        </span>
                    </div>
                    <div className="stat-label">Scoring</div>
                </div>
            </div>


            {[<div key={td["track"]} className="tie-alert">
                TIE ALERT in {td["track"].replace("_", " ").toUpperCase()}
            </div> for td in leaderboard
                if len([r for r in td.get("rankings", []) if r.get("tie_alert")]) > 0]}


            <div className="section">
                <h2 className="section-title mb-4">Leaderboard</h2>
                {[<div key={td["track"]} style={{"marginBottom": "24px"}}>
                    <h3 style={{"marginBottom": "12px"}}>{td["track"].replace("_", " ").toUpperCase()}</h3>
                    <div className="table-container">
                        <table><thead><tr>
                            <th>Rank</th><th>Project</th><th>Team</th><th>Score</th><th>Judges</th>
                        </tr></thead><tbody>
                            {[<tr key={r["project_id"]}>
                                <td><span className={"leaderboard-rank" +
                                    (r["rank"] == 1 and " rank-1" or "") +
                                    (r["rank"] == 2 and " rank-2" or "") +
                                    (r["rank"] == 3 and " rank-3" or "")}>
                                    {"#" + String(r["rank"])}</span></td>
                                <td style={{"fontWeight": "600"}}>{r["name"]}
                                    {r["tie_alert"] and <span style={{"color": "var(--error)", "marginLeft": "8px", "fontSize": "11px"}}>TIE</span>}
                                </td>
                                <td className="text-muted">{r["team_name"]}</td>
                                <td className="font-mono text-accent" style={{"fontWeight": "700"}}>{r["avg_score"].toFixed(2)}</td>
                                <td className="font-mono text-muted">{r["num_judges"]}</td>
                            </tr> for r in td.get("rankings", [])]}
                        </tbody></table>
                    </div>
                </div> for td in leaderboard]}
            </div>


            <div className="section">
                <h2 className="section-title mb-4">Judge Progress</h2>
                <div className="card">
                    <table><thead><tr>
                        <th>Judge</th><th>Assigned</th><th>Submitted</th><th>Progress</th>
                    </tr></thead><tbody>
                        {[<tr key={j["judge_email"]}>
                            <td><div style={{"fontWeight": "600"}}>{j["judge_name"]}</div>
                                <div className="text-muted text-sm">{j["judge_email"]}</div></td>
                            <td className="font-mono">{j["assigned"]}</td>
                            <td className="font-mono">{j["submitted"]}</td>
                            <td style={{"minWidth": "120px"}}>
                                <div className="progress-bar-container">
                                    <div className={"progress-bar-fill" + (j["remaining"] == 0 and j["assigned"] > 0 and " complete" or "")}
                                        style={{"width": j["assigned"] > 0 and String(parseInt(String(j["submitted"] / j["assigned"] * 100))) + "%" or "0%"}} />
                                </div>
                            </td>
                        </tr> for j in judges]}
                    </tbody></table>
                </div>
            </div>
        </div>;
    }

    # ── Import Page ──
    def ImportPage() -> JsxElement {
        has projectsCsv: str = "";
        has judgesCsv: str = "";
        has result: str = "";
        has error: str = "";
        has importing: bool = False;

        navigate = useNavigate();

        async def handleImportProjects() -> None {
            error = "";
            result = "";
            importing = True;
            try {
                lines = projectsCsv.trim().split("\n");
                headers = [h.trim() for h in lines[0].split(",")];
                rows = [];
                for line in lines[1:] {
                    if not line.trim() { continue; }
                    vals = [v.trim() for v in line.split(",")];
                    row = {};
                    for (i, h) in enumerate(headers) {
                        row[h] = i < vals.length and vals[i] or "";
                    }
                    rows.append(row);
                }
                r = root spawn import_projects(projects_json=JSON.stringify(rows));
                if r.reports and r.reports.length > 0 {
                    d = r.reports[0];
                    if d.get("error") { error = d["error"]; }
                    else { result = f"Imported {d.get('imported', 0)} projects"; }
                }
            } except Exception as ex { error = f"Failed: {ex}"; }
            importing = False;
        }

        async def handleImportJudges() -> None {
            error = "";
            result = "";
            importing = True;
            try {
                lines = judgesCsv.trim().split("\n");
                headers = [h.trim() for h in lines[0].split(",")];
                rows = [];
                for line in lines[1:] {
                    if not line.trim() { continue; }
                    vals = [v.trim() for v in line.split(",")];
                    row = {};
                    for (i, h) in enumerate(headers) {
                        row[h] = i < vals.length and vals[i] or "";
                    }
                    rows.append(row);
                }
                r = root spawn import_judges(judges_json=JSON.stringify(rows));
                if r.reports and r.reports.length > 0 {
                    d = r.reports[0];
                    if d.get("error") { error = d["error"]; }
                    else { result = f"Imported {d.get('imported', 0)} judges"; }
                }
            } except Exception as ex { error = f"Failed: {ex}"; }
            importing = False;
        }

        async def handleAutoAssign() -> None {
            error = "";
            result = "";
            try {
                r = root spawn auto_assign_judges();
                if r.reports and r.reports.length > 0 {
                    result = f"Auto-assigned {r.reports[0].get('total_assignments', 0)} pairs";
                }
            } except Exception as ex { error = f"Failed: {ex}"; }
        }

        return <div>
            <div className="section-header">
                <h1>Import Data</h1>
                <button className="btn btn-secondary" onClick={lambda -> None { navigate("/organizer"); }}>Back</button>
            </div>
            {error and <div className="alert alert-error">{error}</div>}
            {result and <div className="alert alert-success">{result}</div>}
            <div className="grid grid-2" style={{"marginTop": "20px"}}>
                <div className="card">
                    <h4 className="card-title mb-4">Import Projects (CSV)</h4>
                    <p className="text-muted text-sm mb-2">Columns: name, team_name, track, github_url, demo_url, devpost_url</p>
                    <textarea className="form-textarea" value={projectsCsv}
                        onChange={lambda e: any -> None { projectsCsv = e.target.value; }}
                        placeholder="name,team_name,track,github_url,demo_url,devpost_url\nMyProject,Team A,agentic_ai,https://github.com/..."
                        style={{"minHeight": "150px", "fontFamily": "var(--font-mono)", "fontSize": "12px"}} />
                    <button className="btn btn-primary mt-4" onClick={lambda -> None { handleImportProjects(); }}
                        disabled={importing or not projectsCsv.trim()}>
                        {importing and "Importing..." or "Import Projects"}
                    </button>
                </div>
                <div className="card">
                    <h4 className="card-title mb-4">Import Judges (CSV)</h4>
                    <p className="text-muted text-sm mb-2">Columns: name, email, role, assigned_tracks</p>
                    <textarea className="form-textarea" value={judgesCsv}
                        onChange={lambda e: any -> None { judgesCsv = e.target.value; }}
                        placeholder="name,email,role,assigned_tracks\nJohn Doe,john@umich.edu,judge,agentic_ai"
                        style={{"minHeight": "150px", "fontFamily": "var(--font-mono)", "fontSize": "12px"}} />
                    <button className="btn btn-primary mt-4" onClick={lambda -> None { handleImportJudges(); }}
                        disabled={importing or not judgesCsv.trim()}>
                        {importing and "Importing..." or "Import Judges"}
                    </button>
                </div>
            </div>
            <div className="card mt-4">
                <div className="flex justify-between items-center">
                    <div>
                        <h4 className="card-title">Auto-Assign Judges</h4>
                        <p className="text-muted text-sm mt-2">Assigns judges to projects by track.</p>
                    </div>
                    <button className="btn btn-primary" onClick={lambda -> None { handleAutoAssign(); }}>Auto-Assign</button>
                </div>
            </div>
        </div>;
    }

    # ── Results Page ──
    def ResultsPage() -> JsxElement {
        has results: dict = {};
        has loading: bool = True;

        navigate = useNavigate();

        async can with entry {
            try {
                r = root spawn export_results(track="");
                if r.reports and r.reports.length > 0 { results = r.reports[0]; }
            } except Exception as ex { print(ex); }
            loading = False;
        }

        def exportJSON() -> None {
            blob = Blob([JSON.stringify(results, None, 2)], {"type": "application/json"});
            url = URL.createObjectURL(blob);
            a = document.createElement("a");
            a.href = url;
            a.download = "jachacks_results.json";
            a.click();
        }

        if loading { return <div className="text-muted">Loading...</div>; }
        tracks = results.get("tracks", []);
        awards = results.get("special_awards", []);

        return <div>
            <div className="section-header">
                <h1>Results</h1>
                <div className="flex gap-3">
                    <button className="btn btn-primary" onClick={lambda -> None { exportJSON(); }}>Export JSON</button>
                    <button className="btn btn-secondary" onClick={lambda -> None { navigate("/organizer"); }}>Back</button>
                </div>
            </div>
            {[<div key={t["track"]} className="section" style={{"marginTop": "20px"}}>
                <h2 className="section-title mb-4">{t["track"].replace("_", " ").toUpperCase()}</h2>
                <table><thead><tr>
                    <th>Rank</th><th>Project</th><th>Team</th><th>Score</th><th>Prize</th>
                </tr></thead><tbody>
                    {[<tr key={String(w["rank"])}>
                        <td><span className={"leaderboard-rank" +
                            (w["rank"] == 1 and " rank-1" or "") +
                            (w["rank"] == 2 and " rank-2" or "")}>
                            {"#" + String(w["rank"])}</span></td>
                        <td style={{"fontWeight": "600"}}>{w["project"]}</td>
                        <td className="text-muted">{w["team"]}</td>
                        <td className="font-mono text-accent">{w["score"].toFixed(2)}</td>
                        <td>{w["prize"] and <span className="chip chip-submitted">{w["prize"]}</span>}</td>
                    </tr> for w in t.get("winners", [])]}
                </tbody></table>
            </div> for t in tracks]}
            {len(awards) > 0 and (
                <div className="section">
                    <h2 className="section-title mb-4">Special Awards</h2>
                    <div className="grid grid-2">
                        {[<div key={a["award"]} className="card">
                            <h4 className="card-title">{a["award"]}</h4>
                            <div className="text-muted text-sm">{a["sponsor"]} — {a["prize"]}</div>
                            <div className="mt-2">
                                {a["winner_project"] and (
                                    <span style={{"color": "var(--success)", "fontWeight": "600"}}>Winner: {a["winner_project"]}</span>
                                ) or <span className="text-muted">No winner yet</span>}
                            </div>
                        </div> for a in awards]}
                    </div>
                </div>
            )}
        </div>;
    }

    # ── Main App ──
    def:pub app() -> JsxElement {
        has userRole: str = "";

        can with entry {
            role = localStorage.getItem("jachacks_role");
            if role { userRole = role; }
        }

        def handleLogout() -> None {
            jacLogout();
            localStorage.clear();
            window.location.href = "/";
        }

        roleLabel = "";
        if userRole == "judge" { roleLabel = "JUDGE"; }
        elif userRole == "organizer" { roleLabel = "ORGANIZER"; }
        elif userRole == "sponsor_rep" { roleLabel = "SPONSOR"; }
        elif userRole == "participant" { roleLabel = "HACKER"; }

        return <Router>
            <div className="app-container">
                <nav className="navbar">
                    <div className="navbar-brand">
                        <span className="accent">JAC</span>HACKS
                        <span style={{"fontSize": "12px", "color": "#666", "marginLeft": "4px"}}>JUDGING</span>
                    </div>
                    <div className="navbar-links">
                        {jacIsLoggedIn() and userRole == "judge" and <Link to="/judge">My Projects</Link>}
                        {jacIsLoggedIn() and userRole == "organizer" and (<>
                            <Link to="/organizer">Dashboard</Link>
                            <Link to="/organizer/import">Import</Link>
                            <Link to="/organizer/results">Results</Link>
                        </>)}
                        {jacIsLoggedIn() and userRole == "participant" and <Link to="/submit">My Submission</Link>}
                        {jacIsLoggedIn() and roleLabel and <span className="nav-role-badge">{roleLabel}</span>}
                        {jacIsLoggedIn() and <button onClick={lambda -> None { handleLogout(); }}>Logout</button>}
                    </div>
                </nav>
                <div className="page-content">
                    <Routes>
                        <Route path="/" element={<LoginPage />} />
                        <Route path="/login" element={<LoginPage />} />
                        <Route path="/submit" element={<SubmitPage />} />
                        <Route path="/judge" element={<JudgeDashboard />} />
                        <Route path="/judge/:project_id" element={<JudgeScorePage />} />
                        <Route path="/organizer" element={<OrganizerDashboard />} />
                        <Route path="/organizer/import" element={<ImportPage />} />
                        <Route path="/organizer/results" element={<ResultsPage />} />
                    </Routes>
                </div>
            </div>
        </Router>;
    }
}
