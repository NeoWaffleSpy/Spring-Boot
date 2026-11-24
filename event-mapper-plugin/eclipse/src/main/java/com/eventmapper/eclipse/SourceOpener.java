package com.eventmapper.eclipse;

import org.eclipse.core.resources.IFile;
import org.eclipse.core.resources.ResourcesPlugin;
import org.eclipse.core.runtime.IStatus;
import org.eclipse.core.runtime.Path;
import org.eclipse.core.runtime.Platform;
import org.eclipse.core.runtime.Status;
import org.eclipse.jface.text.BadLocationException;
import org.eclipse.jface.text.IDocument;
import org.eclipse.ui.IEditorPart;
import org.eclipse.ui.IWorkbenchPage;
import org.eclipse.ui.PartInitException;
import org.eclipse.ui.ide.IDE;
import org.eclipse.ui.texteditor.ITextEditor;

/** Opens a source file of the workspace at a line. */
final class SourceOpener {

    private SourceOpener() {
    }

    /**
     * @param path absolute file path, as in the page's {@code abs} field
     * @param line 1-based line
     */
    static void open(IWorkbenchPage page, String path, int line) {
        IFile file = ResourcesPlugin.getWorkspace().getRoot().getFileForLocation(Path.fromOSString(path));
        if (file == null || !file.exists()) {
            Platform.getLog(SourceOpener.class).log(new Status(IStatus.WARNING, "com.eventmapper.eclipse",
                    "Event Mapper: " + path + " is not in the workspace"));
            return;
        }
        try {
            IEditorPart editor = IDE.openEditor(page, file, true);
            ITextEditor text = editor instanceof ITextEditor t ? t : editor == null ? null : editor.getAdapter(ITextEditor.class);
            if (text == null || line < 1) {
                return;
            }
            IDocument doc = text.getDocumentProvider().getDocument(text.getEditorInput());
            if (doc != null) {
                int offset = doc.getLineOffset(Math.min(line, doc.getNumberOfLines()) - 1);
                text.selectAndReveal(offset, 0);
            }
        } catch (PartInitException | BadLocationException e) {
            Platform.getLog(SourceOpener.class).log(new Status(IStatus.WARNING, "com.eventmapper.eclipse",
                    "Event Mapper: cannot open " + path + ":" + line, e));
        }
    }
}
