package com.eventmapper.eclipse;

import org.eclipse.core.resources.IProject;
import org.eclipse.core.resources.ResourcesPlugin;
import org.eclipse.core.runtime.Adapters;
import org.eclipse.core.runtime.IPath;
import org.eclipse.jdt.core.IJavaProject;
import org.eclipse.jdt.core.JavaCore;
import org.eclipse.jface.viewers.ISelection;
import org.eclipse.jface.viewers.IStructuredSelection;

import java.util.ArrayList;
import java.util.List;

/** Which Java projects to map, and the folder they are mapped from. */
final class Projects {

    private Projects() {
    }

    /** The Java projects in the selection, or every open Java project when none is selected. */
    static List<IJavaProject> selectedOrAll(ISelection selection) {
        List<IJavaProject> out = selected(selection);
        return out.isEmpty() ? allJava() : out;
    }

    /** The Java projects in the selection (possibly none). */
    static List<IJavaProject> selected(ISelection selection) {
        List<IJavaProject> out = new ArrayList<>();
        if (selection instanceof IStructuredSelection s) {
            for (Object o : s.toList()) {
                IProject p = Adapters.adapt(o, IProject.class);
                IJavaProject jp = p == null ? null : javaProject(p);
                if (jp != null && !out.contains(jp)) {
                    out.add(jp);
                }
            }
        }
        return out;
    }

    /** Every open Java project of the workspace. */
    static List<IJavaProject> all() {
        return allJava();
    }

    private static List<IJavaProject> allJava() {
        List<IJavaProject> out = new ArrayList<>();
        for (IProject p : ResourcesPlugin.getWorkspace().getRoot().getProjects()) {
            IJavaProject jp = javaProject(p);
            if (jp != null) {
                out.add(jp);
            }
        }
        return out;
    }

    /** The open Java projects whose folder is inside this folder (or is it). */
    static List<IJavaProject> under(IPath folder) {
        List<IJavaProject> out = new ArrayList<>();
        for (IJavaProject p : all()) {
            IPath loc = p.getProject().getLocation();
            if (loc != null && folder.isPrefixOf(loc)) {
                out.add(p);
            }
        }
        return out;
    }

    /** Open Java projects with these names, in that order; unknown names are skipped. */
    static List<IJavaProject> named(List<String> names) {
        List<IJavaProject> out = new ArrayList<>();
        List<IJavaProject> all = all();
        for (String n : names) {
            for (IJavaProject p : all) {
                if (p.getElementName().equals(n) && !out.contains(p)) {
                    out.add(p);
                }
            }
        }
        return out;
    }

    private static IJavaProject javaProject(IProject p) {
        try {
            return p.isOpen() && p.hasNature(JavaCore.NATURE_ID) ? JavaCore.create(p) : null;
        } catch (Exception e) {
            return null;
        }
    }

    /** The deepest folder holding every project (the project itself when there is one). */
    static IPath commonRoot(List<IJavaProject> projects) {
        IPath root = null;
        for (IJavaProject p : projects) {
            IPath loc = p.getProject().getLocation();
            if (loc == null) {
                continue;
            }
            root = root == null ? loc : root.uptoSegment(root.matchingFirstSegments(loc));
        }
        // projects with nothing in common (other drives...): fall back to the workspace folder
        return root == null || root.segmentCount() == 0 ? ResourcesPlugin.getWorkspace().getRoot().getLocation() : root;
    }

    /** A display name: the project's for one project, else the common folder's. */
    static String name(List<IJavaProject> projects, IPath root) {
        if (projects.size() == 1) {
            return projects.get(0).getElementName();
        }
        String last = root.lastSegment();
        return last == null ? "event-map" : last;
    }
}
