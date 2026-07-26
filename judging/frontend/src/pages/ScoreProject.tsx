import { useEffect, useState } from "react";
import { useParams, useNavigate } from "react-router-dom";
import { walkerRequest, extractFirst, getStoredEmail } from "../api";
import NavBar from "../components/NavBar";

const CRITERIA = [
  {
    key: "technical_execution",
    label: "Technical Depth",
    weight: 0.35,
    desc: "How well does the code work? How creative is the architecture? Is the demo stable?",
  },
  {
    key: "jac_usage",
    label: "JAC Integration",
    weight: 0.30,
    desc: "How deeply and effectively is JAC used as the backbone? walkers, by llm(), graph-native data, single-file full-stack.",
  },
  {
    key: "creativity",
    label: "Real-World Impact",
    weight: 0.20,
    desc: "Does this solve a real problem? Would anyone actually use it?",
  },
  {
    key: "presentation",
    label: "Presentation",
    weight: 0.15,
    desc: "Can you clearly explain what you built and why it matters? Show, don't tell.",
  },
] as const;

interface Scores {
  technical_execution: number;
  jac_usage: number;
  creativity: number;
  presentation: number;
}

function StarRating({
  value,
  onChange,
  disabled,
}: {
  value: number;
  onChange: (v: number) => void;
  disabled?: boolean;
}) {
  const [hover, setHover] = useState(0);
  return (
    <div style={{ display: "flex", gap: "4px", alignItems: "center" }}>
      {[1, 2, 3, 4, 5].map((star) => (
        <span
          key={star}
          onClick={() => !disabled && onChange(star)}
          onMouseEnter={() => !disabled && setHover(star)}
          onMouseLeave={() => setHover(0)}
          style={{
            cursor: disabled ? "default" : "pointer",
            fontSize: "32px",
            color: star <= (hover || value) ? "#F4622A" : "#333",
            transition: "color 0.15s, transform 0.15s",
            transform:
              star <= hover && !disabled ? "scale(1.2)" : "scale(1)",
            userSelect: "none",
          }}
        >
          &#9733;
        </span>
      ))}
    </div>
  );
}

export default function ScoreProject() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const email = getStoredEmail();

  const [project, setProject] = useState<any>(null);
  const [scores, setScores] = useState<Scores>({
    technical_execution: 1,
    jac_usage: 1,
    creativity: 1,
    presentation: 1,
  });
  const [notes, setNotes] = useState("");
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [success, setSuccess] = useState("");
  const [isSubmitted, setIsSubmitted] = useState(false);
  const [showConfirm, setShowConfirm] = useState(false);
  const [round, setRound] = useState(0);
  const draftKey = `draft:${email}:${id}:${round || 1}`;

  useEffect(() => {
    loadProject();
  }, [id]);

  // Mirror every keystroke to this device so a refresh, a dead battery or a
  // dropped request never costs a judge their marks.
  useEffect(() => {
    if (loading || isSubmitted) return;
    localStorage.setItem(draftKey, JSON.stringify({ scores, notes }));
  }, [scores, notes, draftKey, loading, isSubmitted]);

  async function loadProject() {
    try {
      // Resolve the active round first: a project scored in round 1 must show a
      // blank form in round 2, and the score must be written to that round.
      const cfg = extractFirst(await walkerRequest("get_config", {}));
      const activeRound = Math.max(cfg?.current_round ?? 1, 1);
      setRound(activeRound);

      const res = extractFirst(
        await walkerRequest("get_project_detail", {
          project_id: id,
          email,
          round_num: activeRound,
        })
      );
      if (res) {
        setProject(res);
        if (res.my_score) {
          const s = res.my_score;
          setScores({
            technical_execution: s.technical_execution ?? 1,
            jac_usage: s.jac_usage ?? 1,
            creativity: s.creativity ?? 1,
            presentation: s.presentation ?? 1,
          });
          setNotes(s.notes || "");
          setIsSubmitted(!!s.is_final);
        } else {
          // Nothing on the server for this round — recover an unsent local draft.
          const local = localStorage.getItem(
            `draft:${email}:${id}:${activeRound}`
          );
          if (local) {
            try {
              const d = JSON.parse(local);
              if (d.scores) setScores(d.scores);
              if (d.notes) setNotes(d.notes);
            } catch {}
          }
        }
      }
    } catch (err: any) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }

  function overallScore(): number {
    const weighted =
      scores.technical_execution * 0.35 +
      scores.jac_usage * 0.30 +
      scores.creativity * 0.20 +
      scores.presentation * 0.15;
    return Math.round(weighted * 100) / 100;
  }

  async function save(isFinal: boolean) {
    setError("");
    setSuccess("");
    setSaving(true);
    const payload = {
      email,
      project_id: id,
      technical_execution: scores.technical_execution,
      jac_usage: scores.jac_usage,
      creativity: scores.creativity,
      presentation: scores.presentation,
      notes,
      is_final: isFinal,
      round_num: round || 1,
    };
    // Venue wifi drops. Retry a couple of times before making the judge redo
    // the whole form, and keep a local copy either way.
    let lastErr: any = null;
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        const res = await walkerRequest("save_score", payload);
        const data = extractFirst(res);
        if (data?.error) {
          setError(data.error);
          setSaving(false);
          return;
        }
        localStorage.removeItem(draftKey);
        setSuccess(isFinal ? "Score submitted!" : "Draft saved!");
        setIsSubmitted(isFinal);
        setSaving(false);
        return;
      } catch (err: any) {
        lastErr = err;
        await new Promise((r) => setTimeout(r, 600 * (attempt + 1)));
      }
    }
    setError(
      `${lastErr?.message || "Failed to save"} — your marks are saved on this device, press Submit again.`
    );
    setSaving(false);
  }

  if (loading) {
    return (
      <>
        <NavBar />
        <div className="container">
          <p style={{ color: "var(--text-muted)" }}>Loading...</p>
        </div>
      </>
    );
  }

  if (!project) {
    return (
      <>
        <NavBar />
        <div className="container">
          <p className="error-msg">Project not found</p>
        </div>
      </>
    );
  }

  return (
    <>
      <NavBar />
      <div className="container" style={{ maxWidth: 750 }}>
        <button
          className="btn-secondary"
          style={{ marginBottom: 16 }}
          onClick={() => navigate("/judge")}
        >
          &larr; Back to Dashboard
        </button>

        <div className="card mb-16">
          {project.table_num != null && (
            <div style={{
              display: "flex",
              alignItems: "center",
              gap: 12,
              marginBottom: 12,
              padding: "8px 14px",
              background: "rgba(244, 98, 42, 0.1)",
              border: "1px solid var(--accent)",
              borderRadius: 8,
            }}>
              <div style={{
                width: 40, height: 40, borderRadius: '50%',
                background: 'var(--accent)', color: 'white',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                fontWeight: 800, fontSize: '1.1rem',
                fontFamily: "'Space Mono', monospace",
                flexShrink: 0,
              }}>
                {project.table_num}
              </div>
              <span style={{
                fontFamily: "'Space Mono', monospace",
                fontWeight: 700,
                fontSize: "0.85rem",
                color: "var(--accent)",
              }}>
                TABLE {project.table_num}
              </span>
            </div>
          )}
          {round === 2 && (
            <div style={{
              display: "inline-block",
              marginBottom: 10,
              padding: "4px 12px",
              borderRadius: 6,
              background: "rgba(244, 98, 42, 0.15)",
              border: "1px solid var(--accent)",
              color: "var(--accent)",
              fontFamily: "'Space Mono', monospace",
              fontSize: "0.75rem",
              fontWeight: 700,
              letterSpacing: "0.05em",
            }}>
              ROUND 2 &middot; FINALS
            </div>
          )}
          <h2
            style={{
              fontFamily: "'Syne', sans-serif",
              fontSize: "1.4rem",
              fontWeight: 700,
              marginBottom: 8,
            }}
          >
            {project.name}
          </h2>
          <p style={{ color: "var(--text-muted)", marginBottom: 4 }}>
            {project.team_name} &middot; {project.track}
          </p>
          {project.description && (
            <p
              style={{
                fontSize: "0.9rem",
                marginTop: 12,
                lineHeight: 1.5,
                color: "var(--text-muted)",
              }}
            >
              {project.description}
            </p>
          )}
          <div
            style={{
              display: "flex",
              gap: 16,
              marginTop: 12,
              fontSize: "0.85rem",
            }}
          >
            {project.github_url && (
              <a
                href={project.github_url}
                target="_blank"
                rel="noopener noreferrer"
              >
                GitHub
              </a>
            )}
            {project.demo_url && (
              <a
                href={project.demo_url}
                target="_blank"
                rel="noopener noreferrer"
              >
                Demo
              </a>
            )}
            {project.devpost_url && (
              <a
                href={project.devpost_url}
                target="_blank"
                rel="noopener noreferrer"
              >
                Devpost
              </a>
            )}
          </div>
        </div>

        {isSubmitted && (
          <div style={{ textAlign: "center", padding: "40px 20px" }}>
            <div style={{ fontSize: "3rem", marginBottom: 12 }}>&#9989;</div>
            <h2 style={{ fontFamily: "'Syne', sans-serif", color: "#22C55E", marginBottom: 8 }}>Score Submitted!</h2>
            <p style={{ color: "#888" }}>Your score has been recorded. Go back to the dashboard for your next assignment.</p>
            <button className="btn-primary" onClick={() => navigate("/judge")} style={{ marginTop: 20, padding: "12px 32px" }}>
              &larr; Back to Dashboard
            </button>
          </div>
        )}

        {!isSubmitted && (
        <div className="card">
          <div className="flex-between mb-16">
            <h3
              style={{ fontFamily: "'Syne', sans-serif", fontWeight: 700 }}
            >
              Scoring
            </h3>
            <div
              style={{
                textAlign: "right",
              }}
            >
              <div
                style={{
                  fontSize: "2rem",
                  fontWeight: 700,
                  color: "var(--accent)",
                  fontFamily: "'Space Mono', monospace",
                  lineHeight: 1,
                }}
              >
                {overallScore()}
              </div>
              <div
                style={{
                  fontSize: "0.75rem",
                  color: "var(--text-muted)",
                  marginTop: 2,
                }}
              >
                out of 5.0
              </div>
            </div>
          </div>

          {CRITERIA.map((c) => (
            <div className="criterion-card" key={c.key}>
              <div className="flex-between" style={{ marginBottom: 4 }}>
                <div>
                  <div className="criterion-name">{c.label}</div>
                  <span
                    style={{
                      fontSize: "0.7rem",
                      color: "var(--text-muted)",
                      fontFamily: "'Space Mono', monospace",
                    }}
                  >
                    {c.weight * 100}% weight
                  </span>
                </div>
                <div
                  style={{
                    fontFamily: "'Space Mono', monospace",
                    fontSize: "1.2rem",
                    fontWeight: 700,
                    color: "var(--accent)",
                  }}
                >
                  {scores[c.key as keyof Scores]}/5
                </div>
              </div>
              <div className="criterion-desc">{c.desc}</div>
              <StarRating
                value={scores[c.key as keyof Scores]}
                onChange={(v) =>
                  setScores({ ...scores, [c.key]: v })
                }
                disabled={isSubmitted}
              />
            </div>
          ))}

          <div className="form-group" style={{ marginTop: 8 }}>
            <label>Notes</label>
            <textarea
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
              rows={3}
              placeholder="Optional notes about this project..."
              disabled={isSubmitted}
            />
          </div>

          {error && <p className="error-msg">{error}</p>}
          {success && <p className="success-msg">{success}</p>}

          <div style={{ display: "flex", gap: 12, marginTop: 12 }}>
            <button
              className="btn-secondary"
              onClick={() => save(false)}
              disabled={saving}
            >
              {saving ? "Saving..." : "Save Draft"}
            </button>
            <button
              className="btn-primary"
              onClick={() => setShowConfirm(true)}
              disabled={saving}
            >
              Submit Final
            </button>
          </div>
        </div>
        )}
      </div>

      {showConfirm && (
        <div style={{
          position: "fixed", top: 0, left: 0, right: 0, bottom: 0,
          background: "rgba(0,0,0,0.7)", zIndex: 1000,
          display: "flex", alignItems: "center", justifyContent: "center",
        }}>
          <div style={{
            background: "#1a1a1a", border: "2px solid #F4622A",
            borderRadius: 16, padding: "32px", maxWidth: 400, width: "90%",
            textAlign: "center",
          }}>
            <div style={{ fontSize: "2rem", marginBottom: 12 }}>&#9888;&#65039;</div>
            <h3 style={{ fontFamily: "'Syne', sans-serif", fontWeight: 700, marginBottom: 8 }}>
              Submit Final Score?
            </h3>
            <p style={{ color: "#888", fontSize: "0.9rem", marginBottom: 20 }}>
              This cannot be changed once submitted.
            </p>
            <div style={{ display: "flex", gap: 12, justifyContent: "center" }}>
              <button className="btn-secondary" onClick={() => setShowConfirm(false)}
                style={{ padding: "10px 24px", fontSize: "1rem" }}>
                Cancel
              </button>
              <button className="btn-primary" onClick={() => { setShowConfirm(false); save(true); }}
                style={{ padding: "10px 24px", fontSize: "1rem", fontWeight: 700 }}>
                Submit Score
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
