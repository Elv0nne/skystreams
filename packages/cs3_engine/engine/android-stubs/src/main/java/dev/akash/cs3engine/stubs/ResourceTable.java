package dev.akash.cs3engine.stubs;

import java.util.HashMap;
import java.util.Map;

/**
 * An extension's resources as the stand-ins' device sees them (the spec's "Resources"): the default
 * configuration, night values preferred (the app is dark), the app's language where the extension ships
 * it. A resource only in other configurations (a drawable only for xxhdpi) is still found.
 */
public final class ResourceTable {
    /** The stand-ins' API level (Build.VERSION.SDK_INT): a v35 value isn't for it. */
    static final int SDK = 34;

    private final Arsc arsc;
    private final Map<Integer, Arsc.Entry> chosen = new HashMap<>();
    private final Map<String, Integer> ids = new HashMap<>();

    /** [arsc] as a device in [language] sees it: a language tag ("pt-BR", "zh-Hant", "hi"). */
    public ResourceTable(Arsc arsc, String language) {
        this.arsc = arsc;
        String[] wanted = parts(language);
        Map<Integer, Integer> scores = new HashMap<>();
        for (Arsc.Entry entry : arsc.entries) {
            ids.putIfAbsent(entry.type + "/" + entry.name, entry.id);
            int score = score(entry.config, wanted[0], wanted[1], wanted[2]);
            Integer best = scores.get(entry.id);
            if (best == null || score > best) {
                scores.put(entry.id, score);
                chosen.put(entry.id, entry);
            }
        }
    }

    /**
     * How well [config] fits this device; far below zero when it doesn't fit at all (then it's a last resort).
     * A language must be the app's; a region or script it names must be the app's too, where the app names
     * one, and counts a little against it where the app doesn't (values-pt over values-pt-rBR for "pt").
     */
    private static int score(Arsc.Config config, String language, String script, String region) {
        int score = 0;
        if (config.other || config.sdk > SDK) score -= 1_000_000;
        if (!config.language.isEmpty()) {
            if (canonical(config.language).equals(language)) {
                score += 10_000 + named(config.region, region, 1_000) + named(config.script, script, 500);
            } else {
                score -= 1_000_000;
            }
        }
        score += config.night == 2 ? 200 : config.night == 0 ? 100 : 0;
        return score + config.sdk;
    }

    private static int named(String mine, String wanted, int weight) {
        if (mine.isEmpty()) return 0;
        if (wanted.isEmpty()) return -weight / 10;
        return mine.equalsIgnoreCase(wanted) ? weight : -1_000_000;
    }

    /** A language tag's language (canonical), script and region; "" for those it lacks. Other subtags ("apc") go. */
    static String[] parts(String tag) {
        String[] subtags = tag == null ? new String[0] : tag.split("[-_]");
        String language = subtags.length == 0 ? "" : canonical(subtags[0].toLowerCase(java.util.Locale.ROOT));
        String script = "";
        String region = "";
        for (int i = 1; i < subtags.length; i++) {
            String subtag = subtags[i];
            if (script.isEmpty() && region.isEmpty() && subtag.length() == 4 && subtag.chars().allMatch(Character::isLetter)) {
                script = subtag;
            } else if (region.isEmpty() && (subtag.length() == 2 && subtag.chars().allMatch(Character::isLetter)
                || subtag.length() == 3 && subtag.chars().allMatch(Character::isDigit))) {
                region = subtag;
            }
        }
        return new String[] {language, script, region};
    }

    /** Android's old codes and their new ones are one language: Hebrew iw/he, Indonesian in/id, Yiddish ji/yi. */
    private static String canonical(String language) {
        switch (language) {
            case "iw": return "he";
            case "in": return "id";
            case "ji": return "yi";
            default: return language;
        }
    }

    /** The entry [id] resolves to, or null when the table has none. */
    public Arsc.Entry entry(int id) {
        return chosen.get(id);
    }

    /** The id of [type]/[name], or 0 when the table has none (as Resources.getIdentifier). */
    public int identifier(String type, String name) {
        Integer id = ids.get(type + "/" + name);
        return id == null ? 0 : id;
    }

    public String packageName() {
        return arsc.packageName;
    }

    public int packageId() {
        return arsc.packageId;
    }
}
