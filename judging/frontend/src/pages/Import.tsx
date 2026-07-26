import { useState, useEffect } from "react";
import { walkerRequest, authRequest, extractFirst, extractReports } from "../api";
import NavBar from "../components/NavBar";

/**
 * Proper CSV parser that handles multi-line quoted fields (Devpost exports have
 * markdown descriptions with newlines inside quoted fields).
 */
function parseCSV(text: string): Record<string, string>[] {
  const rows: string[][] = [];
  let current: string[] = [];
  let field = "";
  let inQuotes = false;

  for (let i = 0; i < text.length; i++) {
    const char = text[i];
    const next = text[i + 1];

    if (inQuotes) {
      if (char === '"' && next === '"') {
        field += '"';
        i++; // skip escaped quote
      } else if (char === '"') {
        inQuotes = false;
      } else {
        field += char;
      }
    } else {
      if (char === '"') {
        inQuotes = true;
      } else if (char === ',') {
        current.push(field.trim());
        field = "";
      } else if (char === '\n' || (char === '\r' && next === '\n')) {
        current.push(field.trim());
        field = "";
        if (current.length > 1 || current[0] !== "") {
          rows.push(current);
        }
        current = [];
        if (char === '\r') i++; // skip \r\n
      } else {
        field += char;
      }
    }
  }
  // Last field/row
  if (field || current.length > 0) {
    current.push(field.trim());
    if (current.length > 1 || current[0] !== "") {
      rows.push(current);
    }
  }

  if (rows.length < 2) return [];
  const headers = rows[0];
  return rows.slice(1).map((values) => {
    const row: Record<string, string> = {};
    headers.forEach((h, i) => {
      row[h] = values[i] || "";
    });
    return row;
  });
}

interface DevpostProject {
  name: string;
  team_name: string;
  track: string;
  github_url: string;
  demo_url: string;
  devpost_url: string;
  description: string;
  built_with: string;
  prizes: string[];
}

interface Judge {
  name: string;
  email: string;
  role: string;
}

function mapTrack(prizes: string[]): string {
  const all = prizes.join(" ").toLowerCase();
  if (all.includes("agentic")) return "agentic_ai";
  if (all.includes("fintech")) return "fintech_open";
  if (all.includes("social")) return "social_impact";
  // Default to open track
  return "fintech_open";
}

/**
 * Parse Devpost CSV rows into deduplicated projects.
 * Devpost creates one row PER prize opt-in, so a project with 3 prizes = 3 rows.
 * We group by Project Title and merge prizes.
 */
function parseDevpostProjects(rows: Record<string, string>[]): DevpostProject[] {
  const projectMap = new Map<string, DevpostProject>();

  for (const row of rows) {
    const name = row["Project Title"] || "";
    if (!name || name === "Untitled") continue;

    // Include both submitted and drafts with real names

    const existing = projectMap.get(name);
    const prize = row["Opt-In Prize"] || "";

    if (existing) {
      // Merge: just add the prize
      if (prize && !existing.prizes.includes(prize)) {
        existing.prizes.push(prize);
      }
      continue;
    }

    // Build team name from submitter + team members
    const submitterFirst = row["Submitter First Name"] || "";
    const submitterLast = row["Submitter Last Name"] || "";
    const memberCount = parseInt(row["Additional Team Member Count"] || "0");
    const members: string[] = [];
    if (submitterFirst) members.push(`${submitterFirst} ${submitterLast}`.trim());
    for (let i = 1; i <= memberCount; i++) {
      const mFirst = row[`Team Member ${i} First Name`] || "";
      const mLast = row[`Team Member ${i} Last Name`] || "";
      if (mFirst) members.push(`${mFirst} ${mLast}`.trim());
    }

    let team_name = "";
    if (members.length === 1) team_name = members[0];
    else if (members.length <= 3) team_name = members.join(" & ");
    else team_name = `Team ${submitterLast || submitterFirst}`;

    // URLs
    const devpost_url = row["Submission Url"] || "";
    const tryItOut = row['"Try it out" Links'] || row["Try it out Links"] || "";
    const videoDemo = row["Video Demo Link"] || "";
    let github_url = "";
    let demo_url = videoDemo;

    if (tryItOut.includes("github.com")) {
      github_url = tryItOut;
    } else if (tryItOut) {
      demo_url = demo_url || tryItOut;
    }

    // Description - take first 200 chars
    const rawDesc = row["About The Project"] || "";
    const description = rawDesc.replace(/^#+\s*.+$/gm, "").replace(/\n{2,}/g, " ").trim().slice(0, 300);

    const builtWith = row["Built With"] || "";

    projectMap.set(name, {
      name,
      team_name,
      track: mapTrack(prize ? [prize] : []),
      github_url,
      demo_url,
      devpost_url,
      description,
      built_with: builtWith,
      prizes: prize ? [prize] : [],
    });
  }

  // Update tracks based on all collected prizes
  for (const proj of projectMap.values()) {
    proj.track = mapTrack(proj.prizes);
  }

  return Array.from(projectMap.values());
}

const DEFAULT_PASSWORD = "jachacks2026";
const LOGIN_URL = "https://jachacks.org/judging";

function buildInviteMessage(name: string, email: string) {
  return `Hey ${name || email.split("@")[0]}! You're a judge at JacHacks 2026 🎉

Login here to score projects:
🔗 ${LOGIN_URL}
📧 Email: ${email}
🔑 Password: ${DEFAULT_PASSWORD}

You'll rate each project on 4 criteria (1-5 stars). See you at demos!`;
}

async function copyToClipboard(text: string) {
  await navigator.clipboard.writeText(text);
}

async function sendInviteEmail(email: string, name: string) {
  return walkerRequest("send_invite_email", {
    to_email: email,
    to_name: name,
    password: DEFAULT_PASSWORD,
    platform_url: LOGIN_URL,
  });
}

export default function Import() {
  // Judge add state
  const [judgeName, setJudgeName] = useState("");
  const [judgeEmail, setJudgeEmail] = useState("");
  const [addJudgeMsg, setAddJudgeMsg] = useState("");
  const [addJudgeLoading, setAddJudgeLoading] = useState(false);
  const [bulkEmails, setBulkEmails] = useState("");
  const [bulkMsg, setBulkMsg] = useState("");
  const [bulkLoading, setBulkLoading] = useState(false);
  const [judges, setJudges] = useState<Judge[]>([]);
  const [emailStatus, setEmailStatus] = useState<Record<string, string>>({});
  const [copyMsg, setCopyMsg] = useState("");

  // Devpost import state
  const [devpostProjects, setDevpostProjects] = useState<DevpostProject[]>([]);
  const [devpostMsg, setDevpostMsg] = useState("");
  const [devpostFileName, setDevpostFileName] = useState("");

  const [assignMsg, setAssignMsg] = useState("");
  const [groupSize, setGroupSize] = useState(10);
  const [groupMsg, setGroupMsg] = useState("");
  const [groupSummary, setGroupSummary] = useState("");
  const [loading, setLoading] = useState({
    devpost: false,
    judges: false,
    assign: false,
    createGroups: false,
    assignRotation: false,
  });

  async function loadJudges() {
    try {
      const res = await walkerRequest("get_all_judges", {});
      const list = extractReports(res);
      if (Array.isArray(list)) setJudges(list);
    } catch {
      // silently fail
    }
  }

  useEffect(() => {
    loadJudges();
  }, []);

  async function addSingleJudge() {
    if (!judgeName.trim() || !judgeEmail.trim()) return;
    setAddJudgeMsg("");
    setAddJudgeLoading(true);
    try {
      // 1. Create auth account (ignore if already exists)
      try {
        await authRequest("/user/register", {
          username: judgeEmail.trim(),
          password: DEFAULT_PASSWORD,
        });
      } catch {
        // Account may already exist — that's fine, continue
      }
      // 2. Import into judging system
      await walkerRequest("import_judges", {
        judges_json: JSON.stringify([
          { name: judgeName.trim(), email: judgeEmail.trim(), role: "judge" },
        ]),
      });
      // Try sending invite email
      try {
        await sendInviteEmail(judgeEmail.trim(), judgeName.trim());
        setAddJudgeMsg(`✅ Judge added & invite emailed to ${judgeEmail.trim()}!`);
      } catch {
        setAddJudgeMsg(`✅ Judge added! (Email not sent — share credentials manually. Password: ${DEFAULT_PASSWORD})`);
      }
      setJudgeName("");
      setJudgeEmail("");
      loadJudges();
    } catch (err: any) {
      setAddJudgeMsg(`Error: ${err.message}`);
    } finally {
      setAddJudgeLoading(false);
    }
  }

  async function bulkAddJudges() {
    const raw = bulkEmails.trim();
    if (!raw) return;
    setBulkMsg("");
    setBulkLoading(true);

    // Parse emails: split by newlines or commas
    const emails = raw
      .split(/[\n,]+/)
      .map((e) => e.trim())
      .filter((e) => e.length > 0);

    if (emails.length === 0) {
      setBulkMsg("No valid emails found.");
      setBulkLoading(false);
      return;
    }

    let successCount = 0;
    const errors: string[] = [];

    for (const email of emails) {
      try {
        await authRequest("/user/register", {
          username: email,
          password: DEFAULT_PASSWORD,
        });
      } catch (err: any) {
        // might already exist, continue anyway
        errors.push(`${email}: ${err.message}`);
      }
    }

    // Import all as judges
    const judgesData = emails.map((email) => ({
      name: email.split("@")[0],
      email,
      role: "judge",
    }));

    try {
      await walkerRequest("import_judges", {
        judges_json: JSON.stringify(judgesData),
      });
      successCount = emails.length;
    } catch (err: any) {
      setBulkMsg(`Error importing judges: ${err.message}`);
      setBulkLoading(false);
      return;
    }

    const msg = `${successCount} judge(s) created with password: ${DEFAULT_PASSWORD}`;
    setBulkMsg(
      errors.length > 0
        ? `${msg} (${errors.length} registration warning(s) - may already exist)`
        : msg
    );
    setBulkEmails("");
    loadJudges();
    setBulkLoading(false);
  }

  function handleDevpostFile(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
    setDevpostFileName(file.name);
    setDevpostMsg("");
    const reader = new FileReader();
    reader.onload = (ev) => {
      const text = ev.target?.result as string;
      const rows = parseCSV(text);
      if (rows.length === 0) {
        setDevpostMsg("No valid rows found in CSV.");
        setDevpostProjects([]);
        return;
      }
      const projects = parseDevpostProjects(rows);
      setDevpostProjects(projects);
      setDevpostMsg(`Parsed ${projects.length} projects from ${file.name}`);
    };
    reader.readAsText(file);
  }

  async function importDevpostProjects() {
    if (devpostProjects.length === 0) return;
    setDevpostMsg("");
    setLoading((l) => ({ ...l, devpost: true }));
    try {
      await walkerRequest("import_projects", {
        projects_json: JSON.stringify(devpostProjects),
      });
      setDevpostMsg(
        `Imported ${devpostProjects.length} projects successfully!`
      );
    } catch (err: any) {
      setDevpostMsg(`Error: ${err.message}`);
    } finally {
      setLoading((l) => ({ ...l, devpost: false }));
    }
  }


  async function autoAssign() {
    setAssignMsg("");
    setLoading((l) => ({ ...l, assign: true }));
    try {
      await walkerRequest("auto_assign_judges", {});
      setAssignMsg("Judges auto-assigned to projects by track!");
    } catch (err: any) {
      setAssignMsg(`Error: ${err.message}`);
    } finally {
      setLoading((l) => ({ ...l, assign: false }));
    }
  }

  return (
    <>
      <NavBar />
      <div className="container">
        <h1 className="page-title">Import Data</h1>

        <div style={{ display: "grid", gap: 24 }}>
          {/* ===== ADD JUDGES SECTION ===== */}
          <div className="card">
            <h3
              style={{
                fontFamily: "'Syne', sans-serif",
                fontWeight: 700,
                marginBottom: 8,
              }}
            >
              Add Judges
            </h3>
            <p
              style={{
                color: "var(--text-muted)",
                fontSize: "0.85rem",
                marginBottom: 20,
              }}
            >
              Create judge accounts. Each judge gets a login with the default
              password.
            </p>

            {/* Single judge form */}
            <div
              style={{
                display: "grid",
                gridTemplateColumns: "1fr 1fr auto",
                gap: 12,
                alignItems: "end",
                marginBottom: 16,
              }}
            >
              <div className="form-group" style={{ marginBottom: 0 }}>
                <label>Name</label>
                <input
                  type="text"
                  placeholder="Dr. Smith"
                  value={judgeName}
                  onChange={(e) => setJudgeName(e.target.value)}
                />
              </div>
              <div className="form-group" style={{ marginBottom: 0 }}>
                <label>Email</label>
                <input
                  type="email"
                  placeholder="smith@example.com"
                  value={judgeEmail}
                  onChange={(e) => setJudgeEmail(e.target.value)}
                />
              </div>
              <button
                className="btn-primary"
                onClick={addSingleJudge}
                disabled={
                  addJudgeLoading ||
                  !judgeName.trim() ||
                  !judgeEmail.trim()
                }
                style={{ height: 42 }}
              >
                {addJudgeLoading ? "Adding..." : "Add Judge"}
              </button>
            </div>

            {addJudgeMsg && (
              <p
                style={{
                  fontSize: "0.85rem",
                  marginBottom: 16,
                  padding: "10px 14px",
                  borderRadius: 8,
                  background: addJudgeMsg.startsWith("Error")
                    ? "rgba(239, 68, 68, 0.1)"
                    : "rgba(34, 197, 94, 0.1)",
                  color: addJudgeMsg.startsWith("Error")
                    ? "var(--danger)"
                    : "var(--success)",
                  border: addJudgeMsg.startsWith("Error")
                    ? "1px solid rgba(239, 68, 68, 0.2)"
                    : "1px solid rgba(34, 197, 94, 0.2)",
                }}
              >
                {addJudgeMsg}
              </p>
            )}

            {/* Bulk add */}
            <div
              style={{
                borderTop: "1px solid var(--border)",
                paddingTop: 16,
                marginTop: 8,
              }}
            >
              <label
                style={{
                  display: "block",
                  marginBottom: 6,
                  fontSize: "0.85rem",
                  color: "var(--text-muted)",
                  fontWeight: 500,
                }}
              >
                Bulk Add &mdash; paste emails (one per line or comma-separated)
              </label>
              <textarea
                rows={4}
                value={bulkEmails}
                onChange={(e) => setBulkEmails(e.target.value)}
                placeholder={`judge1@example.com\njudge2@example.com, judge3@example.com`}
                style={{ fontFamily: "monospace", fontSize: "0.8rem" }}
              />
              <div
                style={{
                  display: "flex",
                  alignItems: "center",
                  gap: 12,
                  marginTop: 10,
                }}
              >
                <button
                  className="btn-primary"
                  onClick={bulkAddJudges}
                  disabled={bulkLoading || !bulkEmails.trim()}
                >
                  {bulkLoading ? "Creating..." : "Bulk Create Judges"}
                </button>
                {bulkMsg && (
                  <span
                    style={{
                      fontSize: "0.85rem",
                      color: bulkMsg.startsWith("Error")
                        ? "var(--danger)"
                        : "var(--success)",
                    }}
                  >
                    {bulkMsg}
                  </span>
                )}
              </div>
            </div>
          </div>

          {/* ===== DEVPOST CSV IMPORT ===== */}
          <div className="card">
            <h3
              style={{
                fontFamily: "'Syne', sans-serif",
                fontWeight: 700,
                marginBottom: 8,
              }}
            >
              Import from Devpost
            </h3>
            <p
              style={{
                color: "var(--text-muted)",
                fontSize: "0.85rem",
                marginBottom: 16,
              }}
            >
              Upload the CSV export from Devpost. Columns mapped: Project
              Title, Submission Url, Video Demo Link, Desired Prizes, Team
              Members, Website.
            </p>

            <div
              style={{
                display: "flex",
                alignItems: "center",
                gap: 12,
                marginBottom: 16,
              }}
            >
              <label
                className="btn-secondary"
                style={{
                  cursor: "pointer",
                  display: "inline-block",
                }}
              >
                Choose CSV File
                <input
                  type="file"
                  accept=".csv"
                  onChange={handleDevpostFile}
                  style={{ display: "none" }}
                />
              </label>
              {devpostFileName && (
                <span
                  style={{
                    color: "var(--text-muted)",
                    fontSize: "0.85rem",
                  }}
                >
                  {devpostFileName}
                </span>
              )}
            </div>

            {devpostProjects.length > 0 && (
              <>
                <div
                  style={{
                    overflowX: "auto",
                    marginBottom: 16,
                    maxHeight: 400,
                    overflowY: "auto",
                  }}
                >
                  <table>
                    <thead>
                      <tr>
                        <th>Name</th>
                        <th>Team</th>
                        <th>Track</th>
                        <th>Prizes</th>
                        <th>Links</th>
                      </tr>
                    </thead>
                    <tbody>
                      {devpostProjects.map((p, i) => (
                        <tr key={i}>
                          <td style={{ fontWeight: 600 }}>{p.name}</td>
                          <td style={{ color: "var(--text-muted)" }}>
                            {p.team_name}
                          </td>
                          <td>
                            <span
                              className="chip"
                              style={{
                                background:
                                  p.track === "agentic_ai"
                                    ? "rgba(139, 92, 246, 0.15)"
                                    : p.track === "social_impact"
                                      ? "rgba(34, 197, 94, 0.15)"
                                      : "rgba(59, 130, 246, 0.15)",
                                color:
                                  p.track === "agentic_ai"
                                    ? "#8B5CF6"
                                    : p.track === "social_impact"
                                      ? "#22C55E"
                                      : "#3B82F6",
                              }}
                            >
                              {p.track}
                            </span>
                          </td>
                          <td style={{ fontSize: "0.75rem", color: "var(--text-muted)", maxWidth: 150 }}>
                            {p.prizes.length > 0 ? p.prizes.join(", ") : "—"}
                          </td>
                          <td>
                            <div style={{ display: "flex", gap: 6 }}>
                              {p.devpost_url && <a href={p.devpost_url} target="_blank" rel="noopener noreferrer" style={{ fontSize: "0.75rem" }}>Devpost</a>}
                              {p.github_url && <a href={p.github_url} target="_blank" rel="noopener noreferrer" style={{ fontSize: "0.75rem" }}>GitHub</a>}
                              {p.demo_url && <a href={p.demo_url} target="_blank" rel="noopener noreferrer" style={{ fontSize: "0.75rem" }}>Demo</a>}
                              {!p.devpost_url && !p.github_url && !p.demo_url && <span style={{ color: "var(--text-muted)", fontSize: "0.75rem" }}>—</span>}
                            </div>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>

                <button
                  className="btn-primary"
                  onClick={importDevpostProjects}
                  disabled={loading.devpost}
                >
                  {loading.devpost
                    ? "Importing..."
                    : `Import All ${devpostProjects.length} Projects`}
                </button>
              </>
            )}

            {devpostMsg && (
              <p
                style={{
                  fontSize: "0.85rem",
                  marginTop: 12,
                  color: devpostMsg.startsWith("Error")
                    ? "var(--danger)"
                    : "var(--success)",
                }}
              >
                {devpostMsg}
              </p>
            )}
          </div>

          {/* ===== AUTO-ASSIGN ===== */}
          <div className="card">
            <h3
              style={{
                fontFamily: "'Syne', sans-serif",
                fontWeight: 700,
                marginBottom: 8,
              }}
            >
              Auto-Assign Judges
            </h3>
            <p
              style={{
                color: "var(--text-muted)",
                fontSize: "0.85rem",
                marginBottom: 12,
              }}
            >
              Automatically assign judges to projects based on matching
              tracks. Run this after importing both projects and judges.
            </p>
            <div
              style={{
                display: "flex",
                alignItems: "center",
                gap: 12,
              }}
            >
              <button
                className="btn-primary"
                onClick={autoAssign}
                disabled={loading.assign}
              >
                {loading.assign ? "Assigning..." : "Auto-Assign Judges"}
              </button>
              {assignMsg && (
                <span
                  style={{
                    fontSize: "0.85rem",
                    color: assignMsg.startsWith("Error")
                      ? "var(--danger)"
                      : "var(--success)",
                  }}
                >
                  {assignMsg}
                </span>
              )}
            </div>
          </div>

          {/* ===== GROUP SETUP ===== */}
          <div className="card">
            <h3
              style={{
                fontFamily: "'Syne', sans-serif",
                fontWeight: 700,
                marginBottom: 8,
              }}
            >
              Group Setup (Rotation Judging)
            </h3>
            <p
              style={{
                color: "var(--text-muted)",
                fontSize: "0.85rem",
                marginBottom: 16,
              }}
            >
              Splits projects into track-pure groups, then pins a pair of judges to each
              group for round 1. Set the number of groups to half your judge count so
              every group gets a pair (20 judges &rarr; 10 groups).
            </p>

            <div style={{ display: "flex", gap: 12, alignItems: "end", marginBottom: 16 }}>
              <div className="form-group" style={{ marginBottom: 0, width: 130 }}>
                <label>Number of groups</label>
                <input
                  type="number"
                  min={1}
                  max={50}
                  value={groupSize}
                  onChange={(e) => setGroupSize(parseInt(e.target.value) || 10)}
                />
              </div>
              <button
                className="btn-primary"
                onClick={async () => {
                  setLoading((l) => ({ ...l, createGroups: true }));
                  setGroupMsg("");
                  setGroupSummary("");
                  try {
                    const data = extractFirst(
                      await walkerRequest("create_groups", {
                        num_groups: groupSize,
                        min_groups_per_track: 2,
                      })
                    );
                    if (data?.error) {
                      setGroupMsg(`Error: ${data.error}`);
                    } else if (data) {
                      const byTrack = (data.by_track || [])
                        .map((t: any) => `${t.track}: ${t.projects} projects in ${t.groups} groups`)
                        .join(" · ");
                      setGroupSummary(
                        `${data.total_groups} groups for ${data.total_projects} projects. ` +
                        `Largest group: ${data.max_group_size}, smallest: ${data.min_group_size}. ` +
                        `${byTrack}`
                      );
                      setGroupMsg(
                        `Groups created. Budget your demo slot off the largest group ` +
                        `(${data.max_group_size} teams).`
                      );
                    }
                  } catch (err: any) {
                    setGroupMsg(`Error: ${err.message}`);
                  } finally {
                    setLoading((l) => ({ ...l, createGroups: false }));
                  }
                }}
                disabled={loading.createGroups}
                style={{ height: 42 }}
              >
                {loading.createGroups ? "Creating..." : "1. Create Groups"}
              </button>
              <button
                className="btn-secondary"
                onClick={async () => {
                  setLoading((l) => ({ ...l, assignRotation: true }));
                  setGroupMsg("");
                  try {
                    const data = extractFirst(await walkerRequest("assign_rotation", {}));
                    if (data?.error) {
                      setGroupMsg(`Error: ${data.error}`);
                    } else if (data) {
                      const unstaffed = data.unstaffed_groups || [];
                      setGroupMsg(
                        `${data.judges} judges pinned across ${data.groups} groups ` +
                        `(${data.projects_per_judge} projects each).` +
                        (unstaffed.length
                          ? ` WARNING: groups ${unstaffed.join(", ")} have no judge — add more judges.`
                          : "")
                      );
                    }
                  } catch (err: any) {
                    setGroupMsg(`Error: ${err.message}`);
                  } finally {
                    setLoading((l) => ({ ...l, assignRotation: false }));
                  }
                }}
                disabled={loading.assignRotation}
                style={{ height: 42 }}
              >
                {loading.assignRotation ? "Assigning..." : "2. Assign Judges"}
              </button>
            </div>

            {groupSummary && (
              <p style={{
                fontSize: "0.85rem",
                color: "var(--text-muted)",
                padding: "10px 14px",
                background: "var(--surface)",
                borderRadius: 8,
                border: "1px solid var(--border)",
                marginBottom: 8,
              }}>
                {groupSummary}
              </p>
            )}

            {groupMsg && (
              <p style={{
                fontSize: "0.85rem",
                color: groupMsg.startsWith("Error") ? "var(--danger)" : "var(--success)",
              }}>
                {groupMsg}
              </p>
            )}
          </div>

          {/* ===== CURRENT JUDGES LIST ===== */}
          {judges.filter(j => j.role === "judge").length > 0 && (
            <div className="card">
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 16 }}>
                <h3 style={{ fontFamily: "'Syne', sans-serif", fontWeight: 700 }}>
                  Judges ({judges.filter(j => j.role === "judge").length})
                </h3>
                <div style={{ display: "flex", gap: 8 }}>
                  <button
                    className="btn-secondary"
                    style={{ fontSize: "0.8rem", padding: "6px 12px" }}
                    onClick={async () => {
                      const judgeList = judges.filter(j => j.role === "judge");
                      const allInvites = judgeList.map(j => buildInviteMessage(j.name, j.email)).join("\n\n---\n\n");
                      await copyToClipboard(allInvites);
                      setCopyMsg("All invites copied!");
                      setTimeout(() => setCopyMsg(""), 3000);
                    }}
                  >
                    📋 Copy All Invites
                  </button>
                  <button
                    className="btn-secondary"
                    style={{ fontSize: "0.8rem", padding: "6px 12px" }}
                    onClick={async () => {
                      const discordMsg = `🎯 **JacHacks 2026 — Judge Login**\n\n🔗 **URL:** ${LOGIN_URL}\n🔑 **Password:** ${DEFAULT_PASSWORD}\n\nYour email is your username. Rate each project 1-5 stars on 4 criteria. Let's go! 🚀`;
                      await copyToClipboard(discordMsg);
                      setCopyMsg("Discord message copied!");
                      setTimeout(() => setCopyMsg(""), 3000);
                    }}
                  >
                    💬 Copy Discord Announcement
                  </button>
                  <button
                    className="btn-primary"
                    style={{ fontSize: "0.8rem", padding: "6px 12px" }}
                    onClick={async () => {
                      const judgeList = judges.filter(j => j.role === "judge");
                      for (const j of judgeList) {
                        setEmailStatus(prev => ({ ...prev, [j.email]: "sending..." }));
                        try {
                          await sendInviteEmail(j.email, j.name);
                          setEmailStatus(prev => ({ ...prev, [j.email]: "✅ sent" }));
                        } catch {
                          setEmailStatus(prev => ({ ...prev, [j.email]: "❌ failed" }));
                        }
                      }
                    }}
                  >
                    ✉️ Email All Judges
                  </button>
                </div>
              </div>
              {copyMsg && (
                <p style={{ fontSize: "0.85rem", color: "var(--success)", marginBottom: 12 }}>{copyMsg}</p>
              )}
              <div style={{ overflowX: "auto" }}>
                <table>
                  <thead>
                    <tr>
                      <th>#</th>
                      <th>Name</th>
                      <th>Email</th>
                      <th>Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    {judges.filter(j => j.role === "judge").map((j, i) => (
                      <tr key={i}>
                        <td style={{ color: "var(--text-muted)" }}>{i + 1}</td>
                        <td style={{ fontWeight: 600 }}>{j.name}</td>
                        <td style={{ color: "var(--text-muted)" }}>{j.email}</td>
                        <td>
                          <div style={{ display: "flex", gap: 6 }}>
                            <button
                              className="btn-secondary"
                              style={{ fontSize: "0.75rem", padding: "4px 8px" }}
                              onClick={async () => {
                                await copyToClipboard(buildInviteMessage(j.name, j.email));
                                setEmailStatus(prev => ({ ...prev, [j.email]: "📋 copied" }));
                                setTimeout(() => setEmailStatus(prev => ({ ...prev, [j.email]: "" })), 2000);
                              }}
                            >
                              Copy Invite
                            </button>
                            <button
                              className="btn-secondary"
                              style={{ fontSize: "0.75rem", padding: "4px 8px" }}
                              onClick={async () => {
                                setEmailStatus(prev => ({ ...prev, [j.email]: "sending..." }));
                                try {
                                  await sendInviteEmail(j.email, j.name);
                                  setEmailStatus(prev => ({ ...prev, [j.email]: "✅ sent" }));
                                } catch {
                                  setEmailStatus(prev => ({ ...prev, [j.email]: "❌ no SMTP" }));
                                }
                              }}
                            >
                              ✉️ Email
                            </button>
                            {emailStatus[j.email] && (
                              <span style={{ fontSize: "0.75rem", color: "var(--text-muted)", alignSelf: "center" }}>
                                {emailStatus[j.email]}
                              </span>
                            )}
                          </div>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          )}
        </div>
      </div>
    </>
  );
}
