package de.blattkarten.android;

import java.text.BreakIterator;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

final class WorksheetCards {
    static final int MAX_LENGTH = 60_000;
    static final List<String> SUBJECTS = Arrays.asList("Allgemein", "Mathematik", "Physik", "Chemie", "Biologie", "Deutsch", "Englisch", "Geschichte", "Erdkunde");
    private static final String[] TERMS = {
        "", "gleichung|parabel|nenner|bruchrechnung|ableitung|koordinaten|pythagoras",
        "spannung|stromstärk|stromkreis|beschleunigung|geschwindigkeit|widerstand|magnetfeld",
        "molekül|oxidation|säure|periodensystem|atombindung|neutralisation|proton",
        "zellkern|mitochondri|zellmembran|photosynthes|chloroplast|erbinformation|organismus|neuron",
        "metapher|gedicht|reimschema|wortart|satzglied|erzähler",
        "grammar|vocabulary|conditional|present tense|past tense|pronoun",
        "weltkrieg|revolution|mittelalter|kaiserreich|industrialisierung|kolonial",
        "klimazon|wasserkreislauf|kontinent|erosion|vulkanismus|erdkruste"
    };
    private static final Pattern DEFINITION = Pattern.compile("^(.{3,75}?)\\s+(ist|sind|bedeutet)\\s+(.{2,350})$", Pattern.CASE_INSENSITIVE);
    private static final Pattern COMPOSITION = Pattern.compile("^(.{3,75}?)\\s+(besteht|bestehen) aus\\s+(.{2,350})$", Pattern.CASE_INSENSITIVE);
    private static final Pattern ACTION = Pattern.compile("^(.{3,75}?)\\s+(enthält|enthalten|reguliert|regulieren|produziert|produzieren|misst|messen|beschreibt|beschreiben)\\s+(.{2,350})$", Pattern.CASE_INSENSITIVE);
    private static final Pattern CAUSE = Pattern.compile("^(.{4,150}?)(?:,)?\\s+weil\\s+(.{4,240})$", Pattern.CASE_INSENSITIVE);
    private static final Pattern GLOSSARY = Pattern.compile("^([\\p{L}][\\p{L}\\p{Zs}\\-]{2,48}):\\s+(.{8,350})$");
    private static final Pattern TASK = Pattern.compile("(?im)^\\s*(?:Übungsaufgaben|Aufgaben|Teste dich)\\s*:?[ \\t]*$|^\\s*(?:Kreuze an|Begründe|Prüfe, welche|Wahr oder falsch|Berechne)\\b");
    private static final Pattern PRONOUN = Pattern.compile("^(?:er|sie|es|dies|das|diese|dieser|dieses|hier|dabei)$", Pattern.CASE_INSENSITIVE);

    static final class Draft {
        final String question;
        final String answer;
        final String source;
        Draft(String question, String answer, String source) {
            this.question = question;
            this.answer = answer;
            this.source = source;
        }
    }

    static String subject(String text) {
        String normalized = text.toLowerCase(Locale.GERMAN);
        int best = 0, second = 0, winner = 0;
        for (int i = 1; i < TERMS.length; i++) {
            int score = 0;
            for (String term : TERMS[i].split("\\|")) if (normalized.contains(term)) score++;
            if (score > best) { second = best; best = score; winner = i; }
            else second = Math.max(second, score);
        }
        return best >= 2 && best > second ? SUBJECTS.get(winner) : SUBJECTS.get(0);
    }

    static List<Draft> make(String text, int limit) {
        Map<String, Draft> cards = new LinkedHashMap<>();
        for (String raw : text.split("\\f")) {
            String page = raw.replace("\u00ad", "").replaceAll("(?<=\\p{L})-\\h*\\R\\h*(?=\\p{Ll})", "");
            Matcher tasks = TASK.matcher(page);
            if (tasks.find()) page = page.substring(0, tasks.start());
            if (page.toLowerCase(Locale.GERMAN).matches("(?s).*welche der folgenden aussagen.*")) continue;
            for (String line : page.split("\\R")) {
                Matcher glossary = GLOSSARY.matcher(line.trim());
                if (glossary.matches() && !glossary.group(1).matches("(?i)hinweis|aufgabe|beispiel|abbildung")) {
                    add(cards, "Was bedeutet " + glossary.group(1) + "?", glossary.group(2), line.trim());
                }
            }
            String prose = page.replaceAll("\\s+", " ").trim();
            BreakIterator sentences = BreakIterator.getSentenceInstance(Locale.GERMAN);
            sentences.setText(prose);
            for (int start = sentences.first(), end = sentences.next(); end != BreakIterator.DONE; start = end, end = sentences.next()) {
                String sentence = prose.substring(start, end).trim();
                if (sentence.endsWith("?") || sentence.length() > 500 || sentence.isEmpty()) continue;
                String body = sentence.replaceFirst("[.!]$", "");
                Matcher match = CAUSE.matcher(body);
                if (match.matches()) {
                    add(cards, "Warum gilt: „" + match.group(1) + "“?", "Weil " + match.group(2) + ".", sentence);
                    continue;
                }
                match = COMPOSITION.matcher(body);
                if (match.matches()) {
                    if (!PRONOUN.matcher(match.group(1)).matches())
                        add(cards, "Woraus " + match.group(2) + " " + article(match.group(1)) + "?", match.group(3) + ".", sentence);
                    continue;
                }
                match = DEFINITION.matcher(body);
                if (match.matches()) {
                    if (!PRONOUN.matcher(match.group(1)).matches())
                        add(cards, ("sind".equalsIgnoreCase(match.group(2)) ? "Was sind " : "Was ist ") + article(match.group(1)) + "?",
                                match.group(3) + ".", sentence);
                    continue;
                }
                match = ACTION.matcher(body);
                if (match.matches() && !PRONOUN.matcher(match.group(1)).matches()) {
                    add(cards, "Was " + match.group(2).toLowerCase(Locale.GERMAN) + " " + article(match.group(1)) + "?",
                            match.group(3) + ".", sentence);
                }
            }
        }
        List<Draft> unique = new ArrayList<>(cards.values());
        if (unique.size() <= limit) return unique;
        List<Draft> sample = new ArrayList<>(limit);
        for (int i = 0; i < limit; i++) sample.add(unique.get(i * (unique.size() - 1) / Math.max(1, limit - 1)));
        return sample;
    }

    private static String article(String value) {
        return value.replaceFirst("^Der ", "der ").replaceFirst("^Die ", "die ").replaceFirst("^Das ", "das ")
                .replaceFirst("^Ein ", "ein ").replaceFirst("^Eine ", "eine ");
    }

    private static void add(Map<String, Draft> cards, String question, String answer, String source) {
        if (answer.trim().isEmpty() || question.length() > 190) return;
        String normalized = question.toLowerCase(Locale.GERMAN);
        String clean = answer.trim();
        clean = clean.substring(0, 1).toUpperCase(Locale.GERMAN) + clean.substring(1);
        cards.putIfAbsent(normalized, new Draft(question, clean, source));
    }
}
