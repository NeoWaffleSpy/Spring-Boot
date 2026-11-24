package com.eventmapper.core.json;

import com.eventmapper.core.model.Edge;
import com.eventmapper.core.model.Graph;
import com.eventmapper.core.model.Node;

import java.util.List;

/**
 * Writes a {@link Graph} in the JSON format of {@code Event_mapper.sh}:
 * {@code {"meta":{...},"edges":[[...]],"nodes":[{...}],"unresolved":[{...}]}}.
 * Only edges between known nodes are written. "&lt;/" is escaped so the JSON can sit inside
 * a {@code <script>} tag of the page.
 */
public final class GraphJsonWriter {

    private GraphJsonWriter() {
    }

    public static String write(Graph g) {
        StringBuilder sb = new StringBuilder(4096);
        sb.append("{\"meta\":{\"root\":").append(str(g.root))
          .append(",\"generated\":").append(str(g.generated))
          .append(",\"files\":").append(g.files)
          .append(",\"special\":").append(str(g.special))
          .append(",\"components\":[");
        sep(sb, g.components, (b, c) -> b.append("{\"dir\":").append(str(c.dir()))
                .append(",\"name\":").append(str(c.name())).append('}'));
        sb.append("]},\"edges\":[");
        List<Edge> edges = g.edges().stream().filter(e -> g.get(e.src()) != null && g.get(e.dst()) != null).toList();
        sep(sb, edges, (b, e) -> b.append('[').append(str(e.src())).append(',').append(str(e.dst()))
                .append(',').append(str(e.kind())).append(',').append(str(e.file() == null ? "" : e.file()))
                .append(',').append(e.line()).append(',').append(str(e.as() == null ? "" : e.as())).append(']'));
        sb.append("],\"nodes\":[");
        sep(sb, List.copyOf(g.nodes()), (b, n) -> node(b, g, n));
        sb.append("],\"unresolved\":[");
        sep(sb, g.unresolved, (b, u) -> b.append("{\"file\":").append(str(u.file()))
                .append(",\"line\":").append(u.line())
                .append(",\"scope\":").append(str(u.scope()))
                .append(",\"text\":").append(str(u.text())).append('}'));
        return sb.append("]}").toString();
    }

    private static void node(StringBuilder b, Graph g, Node n) {
        b.append("{\"id\":").append(str(n.id))
         .append(",\"kind\":").append(str(n.kind))
         .append(",\"label\":").append(str(n.label))
         .append(",\"cls\":").append(str(n.cls == null ? "" : n.cls))
         .append(",\"file\":").append(n.file == null ? "null" : str(n.file))
         .append(",\"abs\":").append(n.file == null ? "null" : str(g.root + "/" + n.file))
         .append(",\"line\":").append(n.line > 0 ? String.valueOf(n.line) : "null")
         .append(",\"roles\":[");
        sep(b, n.roles, (x, r) -> x.append(str(r)));
        b.append("],\"path\":").append(n.path == null ? "null" : str(n.path))
         .append(",\"verb\":").append(n.verb == null ? "null" : str(n.verb))
         .append(",\"aka\":[");
        sep(b, n.aka, (x, a) -> x.append("{\"name\":").append(str(a.name()))
                .append(",\"to\":").append(a.to() == null ? "null" : str(a.to()))
                .append(",\"file\":").append(str(a.file() == null ? "" : a.file()))
                .append(",\"line\":").append(a.line())
                .append(",\"missing\":").append(a.missing()).append('}'));
        b.append("],\"value\":").append(n.value == null ? "null" : str(n.value))
         .append(",\"unres\":").append(n.unres).append('}');
    }

    private interface Part<T> {
        void write(StringBuilder b, T item);
    }

    private static <T> void sep(StringBuilder b, List<T> items, Part<T> part) {
        for (int i = 0; i < items.size(); i++) {
            if (i > 0) {
                b.append(',');
            }
            part.write(b, items.get(i));
        }
    }

    /** A JSON string literal. */
    static String str(String s) {
        StringBuilder b = new StringBuilder(s.length() + 2).append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"' -> b.append("\\\"");
                case '\\' -> b.append("\\\\");
                case '\n' -> b.append("\\n");
                case '\r' -> b.append("\\r");
                case '\t' -> b.append("\\t");
                case '/' -> b.append(i > 0 && s.charAt(i - 1) == '<' ? "\\/" : "/");
                default -> {
                    if (c < 0x20) {
                        b.append(String.format("\\u%04x", (int) c));
                    } else {
                        b.append(c);
                    }
                }
            }
        }
        return b.append('"').toString();
    }
}
