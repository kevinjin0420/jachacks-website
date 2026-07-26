const API_URL = import.meta.env.VITE_API_URL || "";

export async function authRequest(
  endpoint: string,
  body: Record<string, unknown>
): Promise<any> {
  const res = await fetch(`${API_URL}${endpoint}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(text || `Request failed: ${res.status}`);
  }
  return res.json();
}

export async function walkerRequest(
  name: string,
  body: Record<string, unknown> = {}
): Promise<any> {
  // Deliberately unauthenticated. Jac gives every logged-in user their own
  // root, so sending the token made each judge spawn walkers against a private,
  // empty graph — the organizer would import 60 projects and every judge would
  // see zero. All judging data lives on the shared anonymous root, and every
  // walker identifies the caller by an explicit `email` argument rather than by
  // token, so dropping the header is what makes the event data visible to
  // everyone. Login still gates the UI and supplies that email.
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
  };
  const res = await fetch(`${API_URL}/walker/${name}`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(text || `Walker ${name} failed: ${res.status}`);
  }
  const json = await res.json();
  return json;
}

export function extractReports(response: any): any[] {
  if (response?.reports) return response.reports;
  if (response?.data?.reports) return response.data.reports;
  if (Array.isArray(response)) return response;
  return [];
}

export function extractFirst(response: any): any {
  const reports = extractReports(response);
  return reports.length > 0 ? reports[0] : null;
}

export function getStoredEmail(): string {
  return localStorage.getItem("email") || "";
}

export function getStoredRole(): string {
  return localStorage.getItem("role") || "";
}

export function logout() {
  localStorage.removeItem("token");
  localStorage.removeItem("email");
  localStorage.removeItem("role");
  localStorage.removeItem("username");
  window.location.href = "/login";
}
