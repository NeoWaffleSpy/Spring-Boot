package com.eventmapper.core.page;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.security.CodeSource;
import java.util.ArrayList;
import java.util.List;

/**
 * Builds the event map page around a graph JSON. The page is {@code event-map.html} next to this
 * class (it started as a copy of the page {@code Event_mapper.sh} writes, and is now edited here):
 * {@code {{TITLE}}} is replaced by the title, {@code {{DATA}}} by the JSON.
 */
public final class PageRenderer {

    private static final String RESOURCE = "com/eventmapper/core/page/event-map.html";
    /** loaded on first use, so a missing template is a clear error instead of a failed class */
    private static volatile String template;

    private PageRenderer() {
    }

    /** The page as a browser shows it: source locations as plain text. */
    public static String render(String title, String json) {
        return fill(title, json);
    }

    /**
     * The page as an IDE view shows it: source locations clickable (the IDE must define
     * {@code evmapOpen(file, line)} in the page), and the view state of a previous page restored.
     *
     * @param state what the previous page's {@code evmapState()} returned, or {@code null}
     */
    public static String renderForIde(String title, String json, String state) {
        String restore = state == null || state.isBlank() ? "null" : state.replace("</", "<\\/");
        return fill(title, json + ";\nwindow.EVMAP_HOST=true;window.EVMAP_RESTORE=" + restore);
    }

    private static String fill(String title, String data) {
        String page = template().replace("{{TITLE}}", escape(title));
        int at = page.indexOf("{{DATA}}");
        return page.substring(0, at) + data + page.substring(at + "{{DATA}}".length());
    }

    private static String escape(String s) {
        return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;");
    }

    private static String template() {
        String t = template;
        if (t == null) {
            t = load();
            template = t;
        }
        return t;
    }

    /** Reads the template next to this class: through the class, then its class loader, then the thread's. */
    private static String load() {
        List<InputStream> tried = new ArrayList<>();
        try {
            InputStream in = PageRenderer.class.getResourceAsStream("/" + RESOURCE);
            ClassLoader own = PageRenderer.class.getClassLoader();
            if (in == null && own != null) {
                in = own.getResourceAsStream(RESOURCE);
            }
            ClassLoader thread = Thread.currentThread().getContextClassLoader();
            if (in == null && thread != null) {
                in = thread.getResourceAsStream(RESOURCE);
            }
            if (in == null) {
                CodeSource src = PageRenderer.class.getProtectionDomain().getCodeSource();
                throw new IllegalStateException("The page template " + RESOURCE + " is not in the core jar ("
                        + (src == null ? "unknown location" : src.getLocation())
                        + "). Rebuild it with `mvn package` in event-mapper-plugin/core.");
            }
            tried.add(in);
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        } finally {
            for (InputStream in : tried) {
                try {
                    in.close();
                } catch (IOException ignored) {
                    // nothing to do
                }
            }
        }
    }
}
