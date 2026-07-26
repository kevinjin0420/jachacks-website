import { useEffect, useState, useRef, useCallback } from "react";
import { Link } from "react-router-dom";
import { walkerRequest, extractFirst, getStoredEmail } from "../api";
import NavBar from "../components/NavBar";

// Only update state if data actually changed (prevents flicker on the 5s poll)
function useStableState<T>(initial: T): [T, (v: T) => void] {
  const [state, setState] = useState(initial);
  const ref = useRef(JSON.stringify(initial));
  const setStable = useCallback((v: T) => {
    const json = JSON.stringify(v);
    if (json !== ref.current) {
      ref.current = json;
      setState(v);
    }
  }, []);
  return [state, setStable];
}

const TRACK_COLORS: Record<string, { bg: string; text: string }> = {
  agentic_ai: { bg: "rgba(139, 92, 246, 0.15)", text: "#8B5CF6" },
  fintech_open: { bg: "rgba(59, 130, 246, 0.15)", text: "#3B82F6" },
  social_impact: { bg: "rgba(34, 197, 94, 0.15)", text: "#22C55E" },
};

const TRACK_LABELS: Record<string, string> = {
  agentic_ai: "Agentic AI",
  fintech_open: "Fintech / Open",
  social_impact: "Social Impact",
};

function trackStyle(track: string) {
  const c = TRACK_COLORS[track] || { bg: "rgba(136,136,136,0.15)", text: "#888" };
  return { background: c.bg, color: c.text };
}

interface AssignedProject {
  project_id: string;
  name: string;
  team_name: string;
  track: string;
  status: string;
  group_num?: number;
  table_num?: number;
  is_finalist?: boolean;
}

interface Worklist {
  round_num: number;
  group_num: number;
  total: number;
  submitted: number;
  scoring_locked: boolean;
  projects: AssignedProject[];
}

export default function JudgeDashboard() {
  const email = getStoredEmail();
  const [work, setWork] = useStableState<Worklist | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const intervalRef = useRef<number | null>(null);
  const inFlight = useRef(false);
  const firstLoad = useRef(true);

  useEffect(() => {
    load().then(() => {
      firstLoad.current = false;
    });
    intervalRef.current = window.setInterval(load, 5000);
    return () => {
      if (intervalRef.current) clearInterval(intervalRef.current);
    };
  }, []);

  async function load() {
    if (inFlight.current) return;
    inFlight.current = true;
    try {
      const res = extractFirst(
        await walkerRequest("get_assigned_projects", { email })
      );
      if (res?.error) setError(res.error);
      else if (res) {
        setWork(res);
        setError("");
      }
    } catch (err: any) {
      setError(err.message);
    } finally {
      setLoading(false);
      inFlight.current = false;
    }
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

  const projects = work?.projects || [];
  const round = work?.round_num || 1;
  const isFinals = round === 2;
  const done = work?.submitted || 0;
  const total = work?.total || 0;
  const allDone = total > 0 && done >= total;

  return (
    <>
      <NavBar />
      <div className="container">
        <h1 className="page-title">Judge Dashboard</h1>
        {error && <p className="error-msg mb-16">{error}</p>}

        {total === 0 && (
          <div className="card" style={{ textAlign: "center", padding: "30px 24px" }}>
            <div style={{ fontSize: "2rem", marginBottom: 8 }}>&#9203;</div>
            <h2 style={{ fontFamily: "'Syne', sans-serif", fontWeight: 700, marginBottom: 8 }}>
              Nothing assigned yet
            </h2>
            <p style={{ color: "var(--text-muted)", fontSize: "0.9rem" }}>
              The organizer hasn't published assignments. This page updates itself,
              so just leave it open.
            </p>
          </div>
        )}

        {total > 0 && (
          <>
            {/* Round + progress banner */}
            <div
              style={{
                background: isFinals
                  ? "rgba(244, 98, 42, 0.15)"
                  : "rgba(244, 98, 42, 0.08)",
                border: "2px solid var(--accent)",
                borderRadius: 12,
                padding: "18px 24px",
                marginBottom: 20,
              }}
            >
              <div
                style={{
                  fontFamily: "'Syne', sans-serif",
                  fontSize: "1.5rem",
                  fontWeight: 800,
                  color: "var(--accent)",
                  lineHeight: 1.2,
                }}
              >
                {isFinals
                  ? "ROUND 2 · FINALS"
                  : `ROUND 1 · GROUP ${work?.group_num ?? "?"}`}
              </div>
              <div
                style={{
                  color: "var(--text-muted)",
                  fontSize: "0.85rem",
                  marginTop: 4,
                }}
              >
                {isFinals
                  ? "Score every finalist. All judges score all six."
                  : "Work through your tables in order. Score each team right after their demo."}
              </div>

              <div style={{ marginTop: 14 }}>
                <div
                  style={{
                    display: "flex",
                    justifyContent: "space-between",
                    fontSize: "0.8rem",
                    marginBottom: 6,
                    fontFamily: "'Space Mono', monospace",
                  }}
                >
                  <span style={{ color: "var(--text-muted)" }}>PROGRESS</span>
                  <span style={{ color: allDone ? "#22C55E" : "var(--accent)", fontWeight: 700 }}>
                    {done} / {total} submitted
                  </span>
                </div>
                <div
                  style={{
                    height: 8,
                    borderRadius: 4,
                    background: "var(--border)",
                    overflow: "hidden",
                  }}
                >
                  <div
                    style={{
                      height: "100%",
                      width: `${total ? (done / total) * 100 : 0}%`,
                      background: allDone ? "#22C55E" : "var(--accent)",
                      transition: "width 0.3s",
                    }}
                  />
                </div>
              </div>
            </div>

            {work?.scoring_locked && (
              <div
                className="card mb-16"
                style={{ borderColor: "var(--danger)", textAlign: "center" }}
              >
                <strong style={{ color: "var(--danger)" }}>Scoring is locked</strong>
                <p style={{ color: "var(--text-muted)", fontSize: "0.85rem", marginTop: 4 }}>
                  The organizer has closed this round.
                </p>
              </div>
            )}

            {allDone && (
              <div
                className="card mb-16"
                style={{ textAlign: "center", padding: "24px", border: "2px solid #22C55E" }}
              >
                <div style={{ fontSize: "2.5rem", marginBottom: 8 }}>&#9989;</div>
                <h3
                  style={{
                    fontFamily: "'Syne', sans-serif",
                    fontWeight: 700,
                    color: "#22C55E",
                    marginBottom: 4,
                  }}
                >
                  All scores submitted
                </h3>
                <p style={{ color: "var(--text-muted)", fontSize: "0.9rem" }}>
                  {isFinals
                    ? "Thanks! Results are being tallied."
                    : "Leave this page open, it will switch to the finals automatically."}
                </p>
              </div>
            )}

            {/* Worklist */}
            <div className="card">
              <h3
                style={{
                  fontFamily: "'Syne', sans-serif",
                  fontWeight: 700,
                  marginBottom: 12,
                }}
              >
                {isFinals ? "Finalists" : "Your Tables"}
              </h3>
              <div style={{ display: "grid", gap: 10 }}>
                {projects.map((p) => {
                  const scored = p.status === "submitted";
                  const draft = p.status === "in_progress";
                  const card = (
                    <div
                      className="card"
                      style={{
                        display: "flex",
                        alignItems: "center",
                        gap: 14,
                        padding: "14px 18px",
                        cursor: scored ? "default" : "pointer",
                        borderColor: scored ? "rgba(34,197,94,0.4)" : undefined,
                      }}
                    >
                      <div
                        style={{
                          width: 42,
                          height: 42,
                          borderRadius: "50%",
                          background: scored ? "#22C55E" : "var(--accent)",
                          color: "white",
                          display: "flex",
                          alignItems: "center",
                          justifyContent: "center",
                          fontWeight: 800,
                          fontSize: "1.1rem",
                          fontFamily: "'Space Mono', monospace",
                          flexShrink: 0,
                        }}
                      >
                        {scored ? "✓" : p.table_num || "?"}
                      </div>
                      <div style={{ flex: 1, minWidth: 0 }}>
                        <div style={{ fontWeight: 600, fontSize: "0.95rem" }}>{p.name}</div>
                        <div
                          style={{
                            display: "flex",
                            gap: 8,
                            alignItems: "center",
                            marginTop: 3,
                            flexWrap: "wrap",
                          }}
                        >
                          <span style={{ color: "var(--text-muted)", fontSize: "0.8rem" }}>
                            {p.team_name}
                          </span>
                          {p.track && (
                            <span className="chip" style={trackStyle(p.track)}>
                              {TRACK_LABELS[p.track] || p.track}
                            </span>
                          )}
                        </div>
                      </div>
                      <div style={{ flexShrink: 0 }}>
                        {scored ? (
                          <span
                            style={{
                              color: "#22C55E",
                              fontSize: "0.8rem",
                              fontWeight: 700,
                              background: "rgba(34, 197, 94, 0.12)",
                              padding: "4px 10px",
                              borderRadius: 12,
                            }}
                          >
                            Scored
                          </span>
                        ) : (
                          <span
                            style={{
                              color: "var(--accent)",
                              fontSize: "0.8rem",
                              fontWeight: 600,
                            }}
                          >
                            {draft ? "Resume →" : "Score →"}
                          </span>
                        )}
                      </div>
                    </div>
                  );

                  if (scored) {
                    return (
                      <div key={p.project_id} style={{ opacity: 0.75 }}>
                        {card}
                      </div>
                    );
                  }
                  return (
                    <Link
                      key={p.project_id}
                      to={`/judge/${p.project_id}`}
                      style={{ textDecoration: "none", color: "inherit" }}
                    >
                      {card}
                    </Link>
                  );
                })}
              </div>
            </div>
          </>
        )}
      </div>
    </>
  );
}
