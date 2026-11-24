package com.eventmapper.core.page;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class PageRendererTest {

    private static final String JSON = "{\"meta\":{},\"edges\":[],\"nodes\":[],\"unresolved\":[]}";

    @Test
    void fillsTitleAndData() {
        String page = PageRenderer.render("shop <api>", JSON);
        assertTrue(page.startsWith("<!DOCTYPE html>"));
        assertTrue(page.contains("<title>shop &lt;api&gt;</title>"));
        assertTrue(page.contains("const DATA=\n" + JSON + "\n;</script>"));
        assertFalse(page.contains("{{"));
        assertFalse(page.contains("EVMAP_HOST=true"));
    }

    @Test
    void ideVersionSetsTheHostAndRestoresState() {
        String page = PageRenderer.renderForIde("shop", JSON, "{\"q\":\"</script>\"}");
        assertTrue(page.contains(JSON + ";\nwindow.EVMAP_HOST=true;window.EVMAP_RESTORE={\"q\":\"<\\/script>\"}"));
        assertTrue(PageRenderer.renderForIde("shop", JSON, null).contains("window.EVMAP_RESTORE=null"));
    }
}
