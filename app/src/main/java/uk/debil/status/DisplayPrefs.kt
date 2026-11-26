package uk.debil.status

import android.content.Context

/** Which items the detail screen shows. All on by default; changed in Settings. */
enum class DetailItem(val key: String, val label: String) {
    STATE("show_state", "Status and since"),
    MESSAGE("show_message", "Kuma's message"),
    PING("show_ping", "Response time"),
    GRAPH("show_graph", "Response graph"),
    UPTIME("show_uptime", "24h uptime"),
    CERT("show_cert", "Certificate expiry");

    fun isOn(ctx: Context): Boolean = prefs(ctx).getBoolean(key, true)

    fun set(ctx: Context, on: Boolean) {
        prefs(ctx).edit().putBoolean(key, on).apply()
    }

    private companion object {
        fun prefs(ctx: Context) = ctx.getSharedPreferences("display", Context.MODE_PRIVATE)
    }
}
