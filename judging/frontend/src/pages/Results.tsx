import { useEffect, useRef, useState } from "react";
import { walkerRequest, extractFirst, extractReports } from "../api";
import NavBar from "../components/NavBar";

const TRACK_LABELS: Record<string, string> = {
  agentic_ai: "Agentic AI",
  fintech_open: "Fintech / Open",
  social_impact: "Social Impact",
};

function trackLabel(t: string) {
  return TRACK_LABELS[t] || t || "All Tracks";
}

function rankDisplay(rank: number): string {
  if (rank === 1) return "🥇";
  if (rank === 2) return "🥈";
  if (rank === 3) return "🥉";
  return `#${rank}`;
}

interface Ranking {
  project_id: string;
  name: string;
  team_name: string;
  rank: number;
  avg_score: number;
  norm_score: number;
  num_judges: number;
  group_num: number;
  is_finalist: boolean;
  tie_alert: boolean;
  prize?: string;
}

export default function Results() {
  const [round, setRound] = useState(1);
  const [results, setResults] = useState<any>(null);
  const [finals, setFinals] = useState<any>(null);
  const [progress, setProgress] = useState<any>(null);
  const [awards, setAwards] = useState<any[]>([]);
  const [projects, setProjects] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const [perTrack, setPerTrack] = useState(2);
  const [selecting, setSelecting] = useState(false);
  const [selectMsg, setSelectMsg] = useState("");
  const [confirmSelect, setConfirmSelect] = useState(false);

  const [awardName, setAwardName] = useState("");
  const [awardSponsor, setAwardSponsor] = useState("");
  const [awardPrize, setAwardPrize] = useState("");
  const [awardMsg, setAwardMsg] = useState("");

  const inFlight = useRef(false);
  const firstLoad = useRef(true);

  useEffect(() => {
    loadData().then(() => (firstLoad.current = false));
    const iv = window.setInterval(loadData, 5000);
    return () => clearInterval(iv);
  }, [round]);

  async function loadData() {
    if (inFlight.current) return;
    inFlight.current = true;
    try {
      const [resResults, resFinals, resProgress, resAwards, resProjects] =
        await Promise.all([
          walkerRequest("export_results", { track: "", round_num: round }),
          walkerRequest("get_finalists", {}),
          walkerRequest("get_progress", { round_num: round }),
          walkerRequest("get_awards", {}),
          walkerRequest("get_all_projects", {}),
        ]);
      setResults(extractFirst(resResults));
      setFinals(extractFirst(resFinals));
      setProgress(extractFirst(resProgress));
      setAwards(extractReports(resAwards));
      setProjects(extractReports(resProjects));
      setError("");
    } catch (err: any) {
      setError(err.message);
    } finally {
      setLoading(false);
      inFlight.current = false;
    }
  }

  async function selectFinalists() {
    setSelecting(true);
    setSelectMsg("");
    try {
      const res = extractFirst(
        await walkerRequest("select_finalists", { per_track: perTrack })
      );
      if (res?.error) setSelectMsg(`Error: ${res.error}`);
      else {
        setSelectMsg(
          `${res.total_finalists} finalists locked in. All ${res.judges_assigned} judges now see round 2.`
        );
        setRound(2);
      }
      await loadData();
    } catch (err: any) {
      setSelectMsg(`Error: ${err.message}`);
    } finally {
      setSelecting(false);
    }
  }

  async function resetFinalists() {
    if (!window.confirm("Undo the finalist selection and return to round 1?")) return;
    try {
      await walkerRequest("reset_finalists", {});
      await walkerRequest("assign_rotation", {});
      setSelectMsg("Finals reset. Judges are back on their round-1 groups.");
      setRound(1);
      await loadData();
    } catch (err: any) {
      setSelectMsg(`Error: ${err.message}`);
    }
  }

  async function createAward() {
    setAwardMsg("");
    try {
      await walkerRequest("create_award", {
        name: awardName,
        sponsor: awardSponsor,
        prize_description: awardPrize,
      });
      setAwardMsg("Award created!");
      setAwardName("");
      setAwardSponsor("");
      setAwardPrize("");
      setAwards(extractReports(await walkerRequest("get_awards", {})));
    } catch (err: any) {
      setAwardMsg(`Error: ${err.message}`);
    }
  }

  async function setWinner(awardId: string, projectId: string) {
    try {
      await walkerRequest("set_award_winner", {
        award_id: awardId,
        project_id: projectId,
      });
      setAwards(extractReports(await walkerRequest("get_awards", {})));
    } catch (err: any) {
      alert(err.message);
    }
  }

  function download(filename: string, text: string, type: string) {
    const url = URL.createObjectURL(new Blob([text], { type }));
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    a.click();
    URL.revokeObjectURL(url);
  }

  function exportCsv() {
    const rows = [
      ["round", "track", "rank", "project", "team", "avg_score", "norm_score", "judges", "prize"],
    ];
    for (const t of tracks) {
      for (const r of (t.rankings || []) as Ranking[]) {
        rows.push([
          String(round),
          trackLabel(t.track),
          String(r.rank),
          r.name,
          r.team_name,
          String(r.avg_score),
          String(r.norm_score),
          String(r.num_judges),
          r.prize || "",
        ]);
      }
    }
    const csv = rows
      .map((r) => r.map((c) => `"${String(c).replace(/"/g, '""')}"`).join(","))
      .join("\n");
    download(`jachacks-round${round}.csv`, csv, "text/csv");
  }

  if (loading && firstLoad.current) {
    return (
      <>
        <NavBar />
        <div className="container">
          <p style={{ color: "var(--text-muted)" }}>Loading...</p>
        </div>
      </>
    );
  }

  const tracks = results?.tracks || [];
  const finalsSelected = !!finals?.finals_selected;
  const pct = progress?.percent_complete ?? 0;

  // Who would advance if the organizer pressed the button right now.
  const preview: { track: string; rows: Ranking[] }[] = tracks.map((t: any) => ({
    track: t.track,
    rows: ((t.rankings || []) as Ranking[])
      .filter((r) => r.rank <= perTrack && r.num_judges > 0)
      .slice(0, perTrack),
  }));
  const previewCount = preview.reduce((n, p) => n + p.rows.length, 0);

  return (
    <>
      <NavBar />
      <div className="container">
        <div className="flex-between mb-16" style={{ flexWrap: "wrap", gap: 12 }}>
          <h1 className="page-title" style={{ marginBottom: 0 }}>
            Results
          </h1>
          <div style={{ display: "flex", gap: 8 }}>
            <button className="btn-secondary" onClick={exportCsv} disabled={!results}>
              Export CSV
            </button>
            <button
              className="btn-secondary"
              onClick={() =>
                download(
                  `jachacks-round${round}.json`,
                  JSON.stringify(results, null, 2),
                  "application/json"
                )
              }
              disabled={!results}
            >
              Export JSON
            </button>
          </div>
        </div>

        {error && <p className="error-msg mb-16">{error}</p>}

        {/* Round switch */}
        <div style={{ display: "flex", gap: 8, marginBottom: 16 }}>
          {[1, 2].map((r) => (
            <button
              key={r}
              className={round === r ? "btn-primary" : "btn-secondary"}
              onClick={() => setRound(r)}
            >
              {r === 1 ? "Round 1 · All Teams" : "Round 2 · Finals"}
            </button>
          ))}
        </div>

        {/* Live scoring progress */}
        {progress && (
          <div className="card mb-16">
            <div className="flex-between" style={{ marginBottom: 8 }}>
              <strong style={{ fontFamily: "'Syne', sans-serif" }}>
                Round {round} scoring progress
              </strong>
              <span
                style={{
                  fontFamily: "'Space Mono', monospace",
                  color: pct >= 100 ? "#22C55E" : "var(--accent)",
                  fontWeight: 700,
                }}
              >
                {progress.submitted_scores}/{progress.expected_scores} ({pct}%)
              </span>
            </div>
            <div style={{ height: 8, borderRadius: 4, background: "var(--border)", overflow: "hidden" }}>
              <div
                style={{
                  height: "100%",
                  width: `${Math.min(pct, 100)}%`,
                  background: pct >= 100 ? "#22C55E" : "var(--accent)",
                  transition: "width 0.3s",
                }}
              />
            </div>
            {progress.unscored_projects?.length > 0 && (
              <p style={{ fontSize: "0.8rem", color: "var(--text-muted)", marginTop: 10 }}>
                <strong style={{ color: "var(--danger)" }}>
                  {progress.unscored_projects.length} team(s) with no score yet:
                </strong>{" "}
                {progress.unscored_projects
                  .slice(0, 8)
                  .map((p: any) => `${p.name} (G${p.group_num}/T${p.table_num})`)
                  .join(", ")}
                {progress.unscored_projects.length > 8 && " ..."}
              </p>
            )}
            {progress.judges?.some((j: any) => !j.done) && (
              <p style={{ fontSize: "0.8rem", color: "var(--text-muted)", marginTop: 6 }}>
                <strong>Still scoring:</strong>{" "}
                {progress.judges
                  .filter((j: any) => !j.done)
                  .slice(0, 10)
                  .map((j: any) => `${j.judge_name} (${j.submitted}/${j.assigned})`)
                  .join(", ")}
              </p>
            )}
          </div>
        )}

        {/* Finalist selection */}
        {round === 1 && (
          <div className="card mb-16" style={{ border: "2px solid var(--accent)" }}>
            <h3 style={{ fontFamily: "'Syne', sans-serif", fontWeight: 700, marginBottom: 6 }}>
              Select Finalists
            </h3>
            <p style={{ color: "var(--text-muted)", fontSize: "0.85rem", marginBottom: 14 }}>
              Takes the top teams in each track and puts every judge on all of them for
              round 2. Round-1 ranking uses normalized scores so a harsh judging pair
              doesn't sink a whole group.
            </p>

            <div style={{ display: "flex", gap: 12, alignItems: "end", marginBottom: 14 }}>
              <div className="form-group" style={{ marginBottom: 0, width: 130 }}>
                <label>Per track</label>
                <input
                  type="number"
                  min={1}
                  max={5}
                  value={perTrack}
                  onChange={(e) => setPerTrack(parseInt(e.target.value) || 2)}
                />
              </div>
              <button
                className="btn-primary"
                style={{ height: 42 }}
                disabled={selecting || previewCount === 0}
                onClick={() => setConfirmSelect(true)}
              >
                {selecting ? "Selecting..." : `Lock In ${previewCount} Finalists`}
              </button>
              {finalsSelected && (
                <button className="btn-secondary" style={{ height: 42 }} onClick={resetFinalists}>
                  Undo Selection
                </button>
              )}
            </div>

            {pct < 100 && (
              <p style={{ fontSize: "0.8rem", color: "var(--danger)", marginBottom: 10 }}>
                Round 1 is only {pct}% scored. Selecting now will use partial results.
              </p>
            )}

            <div style={{ display: "grid", gap: 8 }}>
              {preview.map((p) => (
                <div key={p.track}>
                  <div
                    style={{
                      fontFamily: "'Space Mono', monospace",
                      fontSize: "0.7rem",
                      color: "var(--text-muted)",
                      marginBottom: 4,
                    }}
                  >
                    {trackLabel(p.track).toUpperCase()}
                  </div>
                  {p.rows.length === 0 && (
                    <div style={{ fontSize: "0.8rem", color: "var(--text-muted)" }}>
                      No scored teams yet
                    </div>
                  )}
                  {p.rows.map((r) => (
                    <div
                      key={r.project_id}
                      style={{
                        display: "flex",
                        gap: 10,
                        alignItems: "center",
                        padding: "6px 10px",
                        borderRadius: 6,
                        background: "var(--surface)",
                        marginBottom: 4,
                        fontSize: "0.85rem",
                      }}
                    >
                      <strong style={{ color: "var(--accent)" }}>#{r.rank}</strong>
                      <span style={{ flex: 1 }}>{r.name}</span>
                      <span style={{ color: "var(--text-muted)", fontSize: "0.75rem" }}>
                        {r.team_name}
                      </span>
                      {r.tie_alert && (
                        <span
                          style={{
                            fontSize: "0.7rem",
                            color: "#EAB308",
                            fontWeight: 700,
                          }}
                        >
                          TIE
                        </span>
                      )}
                    </div>
                  ))}
                </div>
              ))}
            </div>

            {selectMsg && (
              <p
                style={{
                  fontSize: "0.85rem",
                  marginTop: 12,
                  color: selectMsg.startsWith("Error") ? "var(--danger)" : "var(--success)",
                }}
              >
                {selectMsg}
              </p>
            )}
          </div>
        )}

        {round === 2 && !finalsSelected && (
          <div className="card mb-16">
            <p style={{ color: "var(--text-muted)" }}>
              No finalists selected yet. Switch to Round 1 and use Select Finalists.
            </p>
          </div>
        )}

        {/* Rankings */}
        {tracks.map((t: any) => (
          <div className="card mb-16" key={t.track || "all"}>
            <h3
              style={{
                fontFamily: "'Syne', sans-serif",
                fontWeight: 700,
                color: "var(--accent)",
                marginBottom: 12,
                fontSize: "1.1rem",
              }}
            >
              {trackLabel(t.track)}
            </h3>
            {t.rankings && t.rankings.length > 0 ? (
              <div style={{ overflowX: "auto" }}>
                <table>
                  <thead>
                    <tr>
                      <th>Rank</th>
                      <th>Project</th>
                      <th>Team</th>
                      {round === 1 && <th>Group</th>}
                      <th>Avg</th>
                      {round === 1 && <th>Norm</th>}
                      <th>Judges</th>
                      {round === 2 && <th>Prize</th>}
                    </tr>
                  </thead>
                  <tbody>
                    {(t.rankings as Ranking[]).map((r) => {
                      const top = round === 2 ? r.rank <= 2 : r.rank <= perTrack;
                      return (
                        <tr
                          key={r.project_id}
                          style={top ? { background: "rgba(244, 98, 42, 0.05)" } : undefined}
                        >
                          <td style={{ fontWeight: 700, textAlign: "center", width: 60 }}>
                            {rankDisplay(r.rank)}
                          </td>
                          <td style={{ fontWeight: top ? 700 : 400 }}>
                            {r.name}
                            {r.tie_alert && (
                              <span
                                style={{
                                  marginLeft: 8,
                                  fontSize: "0.65rem",
                                  color: "#EAB308",
                                  fontWeight: 700,
                                }}
                              >
                                TIE
                              </span>
                            )}
                          </td>
                          <td style={{ color: "var(--text-muted)" }}>{r.team_name}</td>
                          {round === 1 && (
                            <td
                              style={{
                                color: "var(--text-muted)",
                                fontFamily: "'Space Mono', monospace",
                                fontSize: "0.8rem",
                              }}
                            >
                              G{r.group_num}
                            </td>
                          )}
                          <td
                            style={{
                              fontWeight: 600,
                              fontFamily: "'Space Mono', monospace",
                              color: top ? "var(--accent)" : "var(--text)",
                            }}
                          >
                            {r.avg_score?.toFixed?.(2) ?? r.avg_score}
                          </td>
                          {round === 1 && (
                            <td
                              style={{
                                fontFamily: "'Space Mono', monospace",
                                fontSize: "0.85rem",
                                color:
                                  r.norm_score > 0 ? "#22C55E" : "var(--text-muted)",
                              }}
                            >
                              {r.norm_score > 0 ? "+" : ""}
                              {r.norm_score?.toFixed?.(2) ?? r.norm_score}
                            </td>
                          )}
                          <td>{r.num_judges}</td>
                          {round === 2 && (
                            <td style={{ color: "var(--success)", fontWeight: 600 }}>
                              {r.prize || "—"}
                            </td>
                          )}
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            ) : (
              <p style={{ color: "var(--text-muted)", fontSize: "0.85rem" }}>
                No scores submitted yet
              </p>
            )}
          </div>
        ))}

        {tracks.length === 0 && (
          <div className="card mb-16">
            <p style={{ color: "var(--text-muted)" }}>No results available yet.</p>
          </div>
        )}

        {/* Special Awards */}
        <div className="card mb-16">
          <h3 style={{ fontFamily: "'Syne', sans-serif", fontWeight: 700, marginBottom: 16 }}>
            Special Awards
          </h3>

          {awards.length > 0 && (
            <div style={{ overflowX: "auto" }}>
              <table style={{ marginBottom: 20 }}>
                <thead>
                  <tr>
                    <th>Award</th>
                    <th>Sponsor</th>
                    <th>Prize</th>
                    <th>Winner</th>
                    <th>Set Winner</th>
                  </tr>
                </thead>
                <tbody>
                  {awards.map((a: any) => (
                    <tr key={a.award_id || a.id || a.name}>
                      <td style={{ fontWeight: 600 }}>{a.name}</td>
                      <td style={{ color: "var(--text-muted)" }}>{a.sponsor}</td>
                      <td style={{ color: "var(--text-muted)" }}>{a.prize_description}</td>
                      <td>
                        {a.winner_name || a.winner_project_id ? (
                          <span style={{ color: "var(--success)", fontWeight: 600 }}>
                            {a.winner_name || a.winner_project_id}
                          </span>
                        ) : (
                          <span style={{ color: "var(--text-muted)" }}>Not set</span>
                        )}
                      </td>
                      <td>
                        <select
                          style={{ width: "auto", minWidth: 140 }}
                          value={a.winner_project_id || ""}
                          onChange={(e) => setWinner(a.award_id || a.id, e.target.value)}
                        >
                          <option value="">Select project</option>
                          {projects.map((p: any) => (
                            <option key={p.project_id || p.id} value={p.project_id || p.id}>
                              {p.name} ({p.team_name})
                            </option>
                          ))}
                        </select>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}

          <h4 className="section-header" style={{ fontSize: "0.9rem", marginBottom: 12 }}>
            Create Award
          </h4>
          <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
            <input
              placeholder="Award name"
              value={awardName}
              onChange={(e) => setAwardName(e.target.value)}
              style={{ flex: "1 1 200px" }}
            />
            <input
              placeholder="Sponsor"
              value={awardSponsor}
              onChange={(e) => setAwardSponsor(e.target.value)}
              style={{ flex: "1 1 150px" }}
            />
            <input
              placeholder="Prize description"
              value={awardPrize}
              onChange={(e) => setAwardPrize(e.target.value)}
              style={{ flex: "1 1 200px" }}
            />
            <button className="btn-primary" onClick={createAward} disabled={!awardName}>
              Create
            </button>
          </div>
          {awardMsg && (
            <p
              style={{
                fontSize: "0.85rem",
                marginTop: 8,
                color: awardMsg.startsWith("Error") ? "var(--danger)" : "var(--success)",
              }}
            >
              {awardMsg}
            </p>
          )}
        </div>
      </div>

      {confirmSelect && (
        <div
          style={{
            position: "fixed",
            inset: 0,
            background: "rgba(0,0,0,0.7)",
            zIndex: 1000,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
          }}
        >
          <div
            style={{
              background: "#1a1a1a",
              border: "2px solid #F4622A",
              borderRadius: 16,
              padding: 32,
              maxWidth: 440,
              width: "90%",
              textAlign: "center",
            }}
          >
            <div style={{ fontSize: "2rem", marginBottom: 12 }}>&#127942;</div>
            <h3 style={{ fontFamily: "'Syne', sans-serif", fontWeight: 700, marginBottom: 8 }}>
              Lock in {previewCount} finalists?
            </h3>
            <p style={{ color: "#888", fontSize: "0.9rem", marginBottom: 20 }}>
              Every judge will immediately switch to round 2 and see only these teams.
              Round-1 scores are kept. You can undo this.
            </p>
            <div style={{ display: "flex", gap: 12, justifyContent: "center" }}>
              <button
                className="btn-secondary"
                onClick={() => setConfirmSelect(false)}
                style={{ padding: "10px 24px" }}
              >
                Cancel
              </button>
              <button
                className="btn-primary"
                onClick={() => {
                  setConfirmSelect(false);
                  selectFinalists();
                }}
                style={{ padding: "10px 24px", fontWeight: 700 }}
              >
                Lock In
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
