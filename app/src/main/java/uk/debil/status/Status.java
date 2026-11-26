package uk.debil.status;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/** Parsed status.json plus how the complication should word it. */
final class Status {
    enum Kind { OK, PROBLEMS, KUMA_ERROR, STALE, OFFLINE }

    /** status.json is rewritten every minute; older than this means its timer has stopped. */
    static final long STALE_AFTER_SECONDS = 5 * 60;

    final Kind kind;
    final List<String> problems;   // e.g. "PKVault DOWN", "Jellyfin SLOW"
    final String checkedAt;        // "HH:MM": status.json's title (last check / last update)
    /** Working services from the optional "up" array; empty when the server doesn't send it. */
    final List<String> up = new ArrayList<>();

    private Status(Kind kind, List<String> problems, String checkedAt) {
        this.kind = kind;
        this.problems = problems;
        this.checkedAt = checkedAt;
    }

    static Status ok(String checkedAt) { return new Status(Kind.OK, new ArrayList<>(), checkedAt); }
    static Status problems(List<String> p, String checkedAt) { return new Status(Kind.PROBLEMS, p, checkedAt); }
    static Status kumaError(String checkedAt) { return new Status(Kind.KUMA_ERROR, new ArrayList<>(), checkedAt); }
    static Status stale(String lastCheck) { return new Status(Kind.STALE, new ArrayList<>(), lastCheck); }
    static Status offline() { return new Status(Kind.OFFLINE, new ArrayList<>(), ""); }

    static Status preview() { return ok("21:47"); }

    /** Accent colour (ARGB) for the list screen. */
    int color() {
        switch (kind) {
            case OK: return 0xFF66DD88;
            case PROBLEMS: return downCount() > 0 ? 0xFFFF6E6E : 0xFFFFC566;
            case OFFLINE: return 0xFFB0B0B0;
            default: return 0xFFFFC566;
        }
    }

    /** Lines for the full list: every problem label, or a single explanation line. */
    List<String> detailLines() {
        List<String> lines = new ArrayList<>();
        if (kind == Kind.PROBLEMS) lines.addAll(problems);
        else if (kind != Kind.OK) lines.add(longText());
        return lines;
    }

    /** Footer under the list, e.g. "Checked 20:17" or "Last update 20:14". */
    String footer() {
        switch (kind) {
            case STALE: return checkedAt.isEmpty() ? "" : "Last update " + checkedAt;
            case OFFLINE: return "No connection";
            default: return checkedAt.isEmpty() ? "" : "Checked " + checkedAt;
        }
    }

    int downCount() {
        int n = 0;
        for (String p : problems) if (p.endsWith(" DOWN")) n++;
        return n;
    }

    private String firstName() {
        if (problems.isEmpty()) return "";
        String p = problems.get(0);
        int i = p.lastIndexOf(' ');
        return i > 0 ? p.substring(0, i) : p;
    }

    /** Main value in a card: kept to ~7 characters so it fits at the card's text size. */
    String shortText() {
        switch (kind) {
            case OK: return "ALL UP";
            case PROBLEMS:
                int down = downCount();
                return down > 0 ? down + " DOWN" : "SLOW";
            case KUMA_ERROR: return "KUMA";
            case STALE: return "STALE";
            default: return "OFFLINE";
        }
    }

    /** Small line under the value. */
    String shortTitle() {
        switch (kind) {
            case OK: return checkedAt;
            case PROBLEMS:
                String name = firstName();
                return problems.size() > 1 ? name + " +" + (problems.size() - 1) : name;
            case KUMA_ERROR: return "NOT READABLE";
            case STALE: return checkedAt.isEmpty() ? "NO UPDATE" : "SINCE " + checkedAt;
            default: return "NO CONNECTION";
        }
    }

    String longText() {
        switch (kind) {
            case OK: return "All up";
            case PROBLEMS: return problems.get(0);
            case KUMA_ERROR: return "Uptime Kuma not readable";
            case STALE: return "Status not updating";
            default: return "Server unreachable";
        }
    }

    String longTitle() {
        switch (kind) {
            case OK: return "Checked " + checkedAt;
            case PROBLEMS:
                if (problems.size() > 1) return "+" + (problems.size() - 1) + " more";
                return checked();
            case KUMA_ERROR: return checked();
            case STALE: return checkedAt.isEmpty() ? "Homelab" : "Last update " + checkedAt;
            default: return "Homelab";
        }
    }

    private String checked() {
        return checkedAt.isEmpty() ? "Homelab" : "Checked " + checkedAt;
    }

    String description() {
        switch (kind) {
            case OK: return "Homelab: all up";
            case PROBLEMS: return String.format(Locale.UK, "Homelab: %d problem(s), %s",
                    problems.size(), String.join(", ", problems));
            default: return "Homelab: " + longText();
        }
    }
}
