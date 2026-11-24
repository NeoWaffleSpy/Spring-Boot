package com.eventmapper.eclipse;

import com.eventmapper.core.code.Argument;
import com.eventmapper.core.code.CallSite;
import com.eventmapper.core.code.CodeModel;
import com.eventmapper.core.code.MethodRef;
import com.eventmapper.core.code.SourceLocation;
import org.eclipse.core.resources.IFile;
import org.eclipse.core.resources.IResource;
import org.eclipse.core.runtime.CoreException;
import org.eclipse.core.runtime.IPath;
import org.eclipse.core.runtime.IProgressMonitor;
import org.eclipse.core.runtime.OperationCanceledException;
import org.eclipse.jdt.core.ICompilationUnit;
import org.eclipse.jdt.core.IJavaElement;
import org.eclipse.jdt.core.IJavaProject;
import org.eclipse.jdt.core.IMember;
import org.eclipse.jdt.core.ISourceRange;
import org.eclipse.jdt.core.JavaCore;
import org.eclipse.jdt.core.JavaModelException;
import org.eclipse.jdt.core.dom.AST;
import org.eclipse.jdt.core.dom.ASTNode;
import org.eclipse.jdt.core.dom.ASTParser;
import org.eclipse.jdt.core.dom.ASTRequestor;
import org.eclipse.jdt.core.dom.BooleanLiteral;
import org.eclipse.jdt.core.dom.CharacterLiteral;
import org.eclipse.jdt.core.dom.CompilationUnit;
import org.eclipse.jdt.core.dom.Expression;
import org.eclipse.jdt.core.dom.IMethodBinding;
import org.eclipse.jdt.core.dom.ITypeBinding;
import org.eclipse.jdt.core.dom.LambdaExpression;
import org.eclipse.jdt.core.dom.MethodDeclaration;
import org.eclipse.jdt.core.dom.MethodInvocation;
import org.eclipse.jdt.core.dom.MethodReference;
import org.eclipse.jdt.core.dom.NodeFinder;
import org.eclipse.jdt.core.dom.NumberLiteral;
import org.eclipse.jdt.core.dom.SimpleName;
import org.eclipse.jdt.core.dom.StringLiteral;
import org.eclipse.jdt.core.dom.TextBlock;
import org.eclipse.jdt.core.search.IJavaSearchConstants;
import org.eclipse.jdt.core.search.IJavaSearchScope;
import org.eclipse.jdt.core.search.SearchEngine;
import org.eclipse.jdt.core.search.SearchMatch;
import org.eclipse.jdt.core.search.SearchParticipant;
import org.eclipse.jdt.core.search.SearchPattern;
import org.eclipse.jdt.core.search.SearchRequestor;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * {@link CodeModel} on top of Eclipse JDT.
 *
 * <p>Calls are found with JDT's search index (references to any method with that name, resolved
 * or not), then each file with matches is parsed once with bindings, and every argument is
 * resolved by the compiler: constant values, method-reference targets, receiver types.
 */
final class JdtCodeModel implements CodeModel {

    private final IPath root;
    private final IProgressMonitor monitor;
    private final IJavaSearchScope scope;
    /** line start offsets per compilation unit, for declarations found through bindings */
    private final Map<ICompilationUnit, int[]> lineStarts = new HashMap<>();

    JdtCodeModel(List<IJavaProject> projects, IPath root, IProgressMonitor monitor) {
        this.root = root;
        this.monitor = monitor;
        this.scope = SearchEngine.createJavaSearchScope(projects.toArray(new IJavaElement[0]), IJavaSearchScope.SOURCES);
    }

    @Override
    public String rootPath() {
        return root.toPortableString();
    }

    @Override
    public void checkCanceled() {
        if (monitor.isCanceled()) {
            throw new OperationCanceledException();
        }
    }

    @Override
    public List<CallSite> findCalls(Set<String> methodNames) {
        // 1. search: matches grouped by file and project
        Map<IJavaProject, Map<ICompilationUnit, List<SearchMatch>>> byProject = new LinkedHashMap<>();
        for (String name : methodNames) {
            checkCanceled();
            SearchPattern pattern = SearchPattern.createPattern(name, IJavaSearchConstants.METHOD,
                    IJavaSearchConstants.REFERENCES, SearchPattern.R_EXACT_MATCH | SearchPattern.R_CASE_SENSITIVE);
            try {
                new SearchEngine().search(pattern, new SearchParticipant[]{SearchEngine.getDefaultSearchParticipant()}, scope,
                        new SearchRequestor() {
                            @Override
                            public void acceptSearchMatch(SearchMatch match) {
                                if (match.getResource() instanceof IFile file) {
                                    ICompilationUnit cu = JavaCore.createCompilationUnitFrom(file);
                                    if (cu != null) {
                                        byProject.computeIfAbsent(cu.getJavaProject(), p -> new LinkedHashMap<>())
                                                .computeIfAbsent(cu, c -> new ArrayList<>()).add(match);
                                    }
                                }
                            }
                        }, monitor);
            } catch (CoreException e) {
                throw new IllegalStateException("Java search failed for " + name, e);
            }
        }

        // 2. parse the files with matches, with bindings, a project at a time
        List<CallSite> out = new ArrayList<>();
        for (Map.Entry<IJavaProject, Map<ICompilationUnit, List<SearchMatch>>> p : byProject.entrySet()) {
            Map<ICompilationUnit, List<SearchMatch>> files = p.getValue();
            ASTParser parser = ASTParser.newParser(AST.getJLSLatest());
            parser.setProject(p.getKey());
            parser.setResolveBindings(true);
            parser.setBindingsRecovery(true);
            parser.createASTs(files.keySet().toArray(new ICompilationUnit[0]), new String[0], new ASTRequestor() {
                @Override
                public void acceptAST(ICompilationUnit source, CompilationUnit ast) {
                    checkCanceled();
                    for (SearchMatch m : files.get(source)) {
                        ASTNode node = NodeFinder.perform(ast, m.getOffset(), m.getLength());
                        // the method name of a call: name <- method invocation
                        if (node instanceof SimpleName name && name.getParent() instanceof MethodInvocation call
                                && call.getName() == name && methodNames.contains(name.getIdentifier())) {
                            out.add(callSite(source, ast, call));
                        }
                    }
                }
            }, monitor);
        }
        return out;
    }

    private CallSite callSite(ICompilationUnit cu, CompilationUnit ast, MethodInvocation call) {
        Expression q = call.getExpression();
        ITypeBinding type = q == null ? null : q.resolveTypeBinding();
        List<Argument> args = new ArrayList<>();
        for (Object o : call.arguments()) {
            args.add(argument(cu, ast, (Expression) o));
        }
        MethodRef in = null;
        SourceLocation lambda = null;
        for (ASTNode n = call.getParent(); n != null; n = n.getParent()) {
            if (lambda == null && n instanceof LambdaExpression) {
                lambda = location(cu, ast, n);
            }
            if (n instanceof MethodDeclaration md) {
                IMethodBinding b = md.resolveBinding();
                in = b != null ? method(b) : null;
                break;
            }
        }
        return new CallSite(call.getName().getIdentifier(), type == null ? null : type.getErasure().getQualifiedName(),
                args, in, lambda, location(cu, ast, call));
    }

    private Argument argument(ICompilationUnit cu, CompilationUnit ast, Expression e) {
        String text = e.toString();
        try {
            text = cu.getSource().substring(e.getStartPosition(), e.getStartPosition() + e.getLength());
        } catch (JavaModelException | RuntimeException ignored) {
            // keep the AST's rendering
        }
        if (e instanceof MethodReference ref) {
            IMethodBinding b = ref.resolveMethodBinding();
            return Argument.methodReference(text, b == null ? null : method(b));
        }
        if (e instanceof LambdaExpression) {
            return Argument.lambda(text, location(cu, ast, e));
        }
        Object value = e.resolveConstantExpressionValue();
        if (value != null) {
            boolean literal = e instanceof StringLiteral || e instanceof TextBlock || e instanceof NumberLiteral
                    || e instanceof CharacterLiteral || e instanceof BooleanLiteral;
            return Argument.constant(text, String.valueOf(value), literal);
        }
        return Argument.other(text);
    }

    private MethodRef method(IMethodBinding b) {
        b = b.getMethodDeclaration();
        ITypeBinding c = b.getDeclaringClass().getErasure();
        String simple = c.getName().isEmpty() ? "?" : c.getName();
        String qualified = c.getQualifiedName().isEmpty() ? simple : c.getQualifiedName();
        return new MethodRef(qualified, simple, b.getName(), declaration(b));
    }

    /** Where a method is declared, or null for a library method. */
    private SourceLocation declaration(IMethodBinding b) {
        if (!(b.getJavaElement() instanceof IMember member) || member.isBinary()) {
            return null;
        }
        ICompilationUnit cu = member.getCompilationUnit();
        try {
            ISourceRange range = member.getNameRange();
            if (cu == null || range == null || range.getOffset() < 0) {
                return null;
            }
            String file = relative(cu.getResource());
            return file == null ? null : new SourceLocation(file, lineOf(cu, range.getOffset()));
        } catch (JavaModelException e) {
            return null;
        }
    }

    private SourceLocation location(ICompilationUnit cu, CompilationUnit ast, ASTNode node) {
        String file = relative(cu.getResource());
        return file == null ? null : new SourceLocation(file, ast.getLineNumber(node.getStartPosition()));
    }

    /** Path relative to the root, or the absolute path when the file is outside it. */
    private String relative(IResource r) {
        IPath loc = r == null ? null : r.getLocation();
        if (loc == null) {
            return null;
        }
        return root.isPrefixOf(loc) ? loc.makeRelativeTo(root).toPortableString() : loc.toPortableString();
    }

    private int lineOf(ICompilationUnit cu, int offset) throws JavaModelException {
        int[] starts = lineStarts.get(cu);
        if (starts == null) {
            String src = cu.getSource();
            List<Integer> s = new ArrayList<>();
            s.add(0);
            for (int i = 0; src != null && i < src.length(); i++) {
                if (src.charAt(i) == '\n') {
                    s.add(i + 1);
                }
            }
            starts = s.stream().mapToInt(Integer::intValue).toArray();
            lineStarts.put(cu, starts);
        }
        int lo = 0, hi = starts.length - 1;
        while (lo < hi) {
            int mid = (lo + hi + 1) >>> 1;
            if (starts[mid] <= offset) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        return lo + 1;
    }
}
