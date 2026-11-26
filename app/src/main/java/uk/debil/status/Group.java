package uk.debil.status;

import java.util.ArrayList;
import java.util.List;

/** One category from the optional "groups" field of status.json (e.g. an Uptime Kuma group). */
final class Group {
    final String name;
    final List<String> problems = new ArrayList<>(); // "Sonarr DOWN", "Radarr SLOW"
    final List<String> up = new ArrayList<>();       // "Jellyfin"

    Group(String name) {
        this.name = name;
    }

    int downCount() {
        int n = 0;
        for (String p : problems) if (p.endsWith(" DOWN")) n++;
        return n;
    }

    int slowCount() {
        int n = 0;
        for (String p : problems) if (p.endsWith(" SLOW")) n++;
        return n;
    }

    /** "UP 3 • DOWN 1", plus " • SLOW n" when something is slow. */
    String summary() {
        String s = "UP " + up.size() + " • DOWN " + downCount();
        int slow = slowCount();
        return slow > 0 ? s + " • SLOW " + slow : s;
    }
}
