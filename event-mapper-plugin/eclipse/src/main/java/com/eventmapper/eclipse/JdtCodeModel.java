package com.eventmapper.eclipse;

import com.eventmapper.core.code.AnnotatedMethod;
import com.eventmapper.core.code.Argument;
import com.eventmapper.core.code.CallSite;
import com.eventmapper.core.code.CodeModel;
import com.eventmapper.core.code.ConstantRef;
import com.eventmapper.core.code.MethodRef;
import com.eventmapper.core.code.SourceLocation;
import org.eclipse.core.resources.IFile;
import org.eclipse.core.resources.IResource;
import org.eclipse.core.runtime.CoreException;
import org.eclipse.core.runtime.IPath;
import org.eclipse.core.runtime.IProgressMonitor;
import org.eclipse.core.runtime.NullProgressMonitor;
import org.eclipse.core.runtime.OperationCanceledException;
import org.eclipse.jdt.core.ICompilationUnit;
import org.eclipse.jdt.core.IField;
import org.eclipse.jdt.core.IJavaElement;
import org.eclipse.jdt.core.IJavaProject;
import org.eclipse.jdt.core.IMember;
import org.eclipse.jdt.core.IMethod;
import org.eclipse.jdt.core.IPackageFragment;
import org.eclipse.jdt.core.IPackageFragmentRoot;
import org.eclipse.jdt.core.ISourceRange;
import org.eclipse.jdt.core.IType;
import org.eclipse.jdt.core.JavaCore;
import org.eclipse.jdt.core.JavaModelException;
import org.eclipse.jdt.core.dom.AST;
import org.eclipse.jdt.core.dom.ASTNode;
import org.eclipse.jdt.core.dom.ASTParser;
import org.eclipse.jdt.core.dom.ASTRequestor;
import org.eclipse.jdt.core.dom.AbstractTypeDeclaration;
import org.eclipse.jdt.core.dom.AnonymousClassDeclaration;
import org.eclipse.jdt.core.dom.ArrayInitializer;
import org.eclipse.jdt.core.dom.BodyDeclaration;
import org.eclipse.jdt.core.dom.BooleanLiteral;
import org.eclipse.jdt.core.dom.CharacterLiteral;
import org.eclipse.jdt.core.dom.ClassInstanceCreation;
import org.eclipse.jdt.core.dom.CompilationUnit;
import org.eclipse.jdt.core.dom.Expression;
import org.eclipse.jdt.core.dom.FieldAccess;
import org.eclipse.jdt.core.dom.IBinding;
import org.eclipse.jdt.core.dom.IMethodBinding;
import org.eclipse.jdt.core.dom.ITypeBinding;
import org.eclipse.jdt.core.dom.IVariableBinding;
import org.eclipse.jdt.core.dom.InfixExpression;
import org.eclipse.jdt.core.dom.LambdaExpression;
import org.eclipse.jdt.core.dom.MemberValuePair;
import org.eclipse.jdt.core.dom.MethodDeclaration;
import org.eclipse.jdt.core.dom.MethodInvocation;
import org.eclipse.jdt.core.dom.MethodReference;
import org.eclipse.jdt.core.dom.Name;
import org.eclipse.jdt.core.dom.NodeFinder;
import org.eclipse.jdt.core.dom.NormalAnnotation;
import org.eclipse.jdt.core.dom.NumberLiteral;
import org.eclipse.jdt.core.dom.ParenthesizedExpression;
import org.eclipse.jdt.core.dom.SimpleName;
import org.eclipse.jdt.core.dom.SingleMemberAnnotation;
import org.eclipse.jdt.core.dom.SingleVariableDeclaration;
import org.eclipse.jdt.core.dom.StringLiteral;
import org.eclipse.jdt.core.dom.SuperMethodInvocation;
import org.eclipse.jdt.core.dom.TextBlock;
import org.eclipse.jdt.core.dom.ThisExpression;
import org.eclipse.jdt.core.dom.TypeLiteral;
import org.eclipse.jdt.core.search.IJavaSearchConstants;
import org.eclipse.jdt.core.search.IJavaSearchScope;
import org.eclipse.jdt.core.search.SearchEngine;
import org.eclipse.jdt.core.search.SearchMatch;
import org.eclipse.jdt.core.search.SearchParticipant;
import org.eclipse.jdt.core.search.SearchPattern;
import org.eclipse.jdt.core.search.SearchRequestor;

import java.util.ArrayList;
import java.util.Collection;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * {@link CodeModel} on top of Eclipse JDT.
 *
 * <p>Calls, annotations and callers are found with JDT's search index, then each file with matches is
 * parsed with bindings and every argument is resolved by the compiler (constant values and the
 * constants they come from, method-reference targets, receiver and object types).
 *
 * <p>Results are cached per file and per query, so a refresh only re-parses the files saved since
 * (and the files whose results point into them). {@link #invalidate} and {@link #clear} drop entries.
 */
final class JdtCodeModel implements CodeModel {

    private static final Pattern ALIAS_INIT = Pattern.compile("=\\s*([A-Za-z_$][\\w$]*(?:\\.[A-Za-z_$][\\w$]*)*)\\s*;?\\s*$");

    private final List<IJavaProject> projects;
    private final IPath root;
    private final IJavaSearchScope scope;
    private IProgressMonitor monitor = new NullProgressMonitor();

    /** per file: its modification stamp when parsed, the results per query, the files they refer to */
    private static final class FileCache {
        final long stamp;
        final Map<String, List<?>> results = new HashMap<>();
        final Set<String> deps = new HashSet<>();

        FileCache(long stamp) {
            this.stamp = stamp;
        }
    }

    private final Map<ICompilationUnit, FileCache> cache = new HashMap<>();
    private final Map<ICompilationUnit, int[]> lineStarts = new HashMap<>();

    JdtCodeModel(List<IJavaProject> projects, IPath root) {
        this.projects = List.copyOf(projects);
        this.root = root;
        this.scope = SearchEngine.createJavaSearchScope(projects.toArray(new IJavaElement[0]), IJavaSearchScope.SOURCES);
    }

    List<IJavaProject> projects() {
        return projects;
    }

    IPath root() {
        return root;
    }

    /** The monitor of the job running the next analysis. */
    void setMonitor(IProgressMonitor monitor) {
        this.monitor = monitor == null ? new NullProgressMonitor() : monitor;
    }

    /** Drops what was cached for these files and for the files whose results refer to them. */
    synchronized void invalidate(Collection<IResource> changed) {
        Set<String> paths = new HashSet<>();
        for (IResource r : changed) {
            String p = relative(r);
            if (p != null) {
                paths.add(p);
            }
        }
        cache.entrySet().removeIf(e -> paths.contains(relative(e.getKey().getResource()))
                || e.getValue().deps.stream().anyMatch(paths::contains));
        lineStarts.keySet().removeIf(cu -> paths.contains(relative(cu.getResource())));
    }

    synchronized void clear() {
        cache.clear();
        lineStarts.clear();
    }

    /** How many results each kind of query gave in the current analysis, for the Error Log. */
    private final Map<String, Integer> stats = new LinkedHashMap<>();

    synchronized void resetStats() {
        stats.clear();
    }

    synchronized Map<String, Integer> stats() {
        return new LinkedHashMap<>(stats);
    }

    private void count(String what, int n) {
        stats.merge(what, n, Integer::sum);
    }

    /** Number of Java files in the source folders of the mapped projects, as JDT sees them. */
    synchronized int sourceFileCount() {
        int n = 0;
        for (IJavaProject p : projects) {
            try {
                for (IPackageFragmentRoot root : p.getPackageFragmentRoots()) {
                    if (root.getKind() != IPackageFragmentRoot.K_SOURCE) {
                        continue;
                    }
                    for (IJavaElement child : root.getChildren()) {
                        if (child instanceof IPackageFragment pkg) {
                            n += pkg.getCompilationUnits().length;
                        }
                    }
                }
            } catch (JavaModelException e) {
                // project not usable: counts as none
            }
        }
        return n;
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

    // ---- queries ------------------------------------------------------------------------

    @Override
    public synchronized List<CallSite> findCalls(Set<String> methodNames) {
        Map<ICompilationUnit, List<SearchMatch>> matches = search(methodNames, IJavaSearchConstants.METHOD);
        List<CallSite> found = perFile("calls:" + new TreeSet<>(methodNames), matches, (cu, ast, ms, deps) -> {
            List<CallSite> out = new ArrayList<>();
            for (SearchMatch m : ms) {
                if (invocationAt(ast, m) instanceof MethodInvocation call && methodNames.contains(call.getName().getIdentifier())) {
                    out.add(callSite(cu, ast, call, deps));
                }
            }
            return out;
        });
        for (CallSite c : found) {
            count(c.methodName() + "()", 1);
        }
        return found;
    }

    @Override
    public synchronized List<AnnotatedMethod> findAnnotatedMethods(Set<String> annotationNames) {
        Map<ICompilationUnit, List<SearchMatch>> matches = search(annotationNames, IJavaSearchConstants.ANNOTATION_TYPE);
        List<AnnotatedMethod> found = perFile("annotations:" + new TreeSet<>(annotationNames), matches, (cu, ast, ms, deps) -> {
            List<AnnotatedMethod> out = new ArrayList<>();
            Set<MethodDeclaration> done = new HashSet<>();
            for (SearchMatch m : ms) {
                ASTNode n = NodeFinder.perform(ast, m.getOffset(), m.getLength());
                while (n != null && !(n instanceof org.eclipse.jdt.core.dom.Annotation)) {
                    n = n.getParent();
                }
                if (n != null && n.getParent() instanceof MethodDeclaration md && done.add(md)) {
                    MethodRef ref = methodRef(cu, ast, md, deps);
                    if (ref != null) {
                        out.add(new AnnotatedMethod(ref, annotations(cu, ast, md, deps),
                                md.getParent() instanceof BodyDeclaration type ? annotations(cu, ast, type, deps) : List.of(),
                                firstParamType(md)));
                    }
                }
            }
            return out;
        });
        for (AnnotatedMethod m : found) {
            for (AnnotatedMethod.Annotation a : m.annotations()) {
                if (annotationNames.contains(a.name())) {
                    count("@" + a.name(), 1);
                }
            }
        }
        return found;
    }

    @Override
    public synchronized List<CallSite> callersOf(MethodRef method) {
        List<SearchPattern> patterns = new ArrayList<>();
        for (IJavaProject p : projects) {
            try {
                IType type = method.className().contains("$") ? null : p.findType(method.className());
                if (type == null) {
                    continue;
                }
                for (IMethod m : type.getMethods()) {
                    if (m.getElementName().equals(method.name())) {
                        patterns.add(SearchPattern.createPattern(m, IJavaSearchConstants.REFERENCES));
                    }
                }
                break;
            } catch (JavaModelException e) {
                // project not usable: try the next one
            }
        }
        if (patterns.isEmpty()) {
            return List.of();
        }
        Map<ICompilationUnit, List<SearchMatch>> matches = search(or(patterns));
        List<CallSite> found = perFile("callers:" + method.id(), matches, (cu, ast, ms, deps) -> {
            List<CallSite> out = new ArrayList<>();
            for (SearchMatch m : ms) {
                ASTNode call = invocationAt(ast, m);
                if (call != null) {
                    out.add(new CallSite(method.name(), null, null, List.of(), enclosing(cu, ast, call, deps),
                            lambda(cu, ast, call), location(cu, ast, call)));
                }
            }
            return out;
        });
        count("followed calls", found.size());
        return found;
    }

    // ---- search and per-file cache ------------------------------------------------------

    private interface Extractor<T> {
        List<T> extract(ICompilationUnit cu, CompilationUnit ast, List<SearchMatch> matches, Set<String> deps);
    }

    private Map<ICompilationUnit, List<SearchMatch>> search(Set<String> names, int searchFor) {
        List<SearchPattern> patterns = new ArrayList<>();
        for (String name : names) {
            patterns.add(SearchPattern.createPattern(name, searchFor, IJavaSearchConstants.REFERENCES,
                    SearchPattern.R_EXACT_MATCH | SearchPattern.R_CASE_SENSITIVE));
        }
        return patterns.isEmpty() ? Map.of() : search(or(patterns));
    }

    private static SearchPattern or(List<SearchPattern> patterns) {
        SearchPattern p = patterns.get(0);
        for (int i = 1; i < patterns.size(); i++) {
            p = SearchPattern.createOrPattern(p, patterns.get(i));
        }
        return p;
    }

    private Map<ICompilationUnit, List<SearchMatch>> search(SearchPattern pattern) {
        checkCanceled();
        Map<ICompilationUnit, List<SearchMatch>> byFile = new LinkedHashMap<>();
        try {
            new SearchEngine().search(pattern, new SearchParticipant[]{SearchEngine.getDefaultSearchParticipant()}, scope,
                    new SearchRequestor() {
                        @Override
                        public void acceptSearchMatch(SearchMatch match) {
                            if (match.getResource() instanceof IFile file) {
                                ICompilationUnit cu = JavaCore.createCompilationUnitFrom(file);
                                if (cu != null) {
                                    byFile.computeIfAbsent(cu, c -> new ArrayList<>()).add(match);
                                }
                            }
                        }
                    }, monitor);
        } catch (CoreException e) {
            throw new IllegalStateException("Java search failed", e);
        }
        return byFile;
    }

    /** Runs the extractor on each file with matches, reusing what is cached for unchanged files. */
    @SuppressWarnings("unchecked")
    private <T> List<T> perFile(String query, Map<ICompilationUnit, List<SearchMatch>> matches, Extractor<T> extractor) {
        count(query.substring(0, query.indexOf(':')) + " search hits", matches.values().stream().mapToInt(List::size).sum());
        List<T> out = new ArrayList<>();
        Map<IJavaProject, List<ICompilationUnit>> toParse = new LinkedHashMap<>();
        for (ICompilationUnit cu : matches.keySet()) {
            FileCache c = cache.get(cu);
            if (c != null && c.stamp == stamp(cu) && c.results.containsKey(query)) {
                out.addAll((List<T>) c.results.get(query));
            } else {
                toParse.computeIfAbsent(cu.getJavaProject(), p -> new ArrayList<>()).add(cu);
            }
        }
        for (Map.Entry<IJavaProject, List<ICompilationUnit>> p : toParse.entrySet()) {
            checkCanceled();
            ASTParser parser = ASTParser.newParser(AST.getJLSLatest());
            parser.setProject(p.getKey());
            parser.setResolveBindings(true);
            parser.setBindingsRecovery(true);
            parser.createASTs(p.getValue().toArray(new ICompilationUnit[0]), new String[0], new ASTRequestor() {
                @Override
                public void acceptAST(ICompilationUnit cu, CompilationUnit ast) {
                    checkCanceled();
                    Set<String> deps = new HashSet<>();
                    List<T> r = extractor.extract(cu, ast, matches.get(cu), deps);
                    long stamp = stamp(cu);
                    FileCache c = cache.get(cu);
                    if (c == null || c.stamp != stamp) {
                        c = new FileCache(stamp);
                        cache.put(cu, c);
                    }
                    c.results.put(query, r);
                    c.deps.addAll(deps);
                    out.addAll(r);
                }
            }, monitor);
        }
        return out;
    }

    /**
     * The method call a reference match points at, or null. JDT's match covers the method name and,
     * for an exact match, its arguments too ({@code emit("x")}), so look up from the node covering it
     * for the call whose name starts at the match.
     */
    private static ASTNode invocationAt(CompilationUnit ast, SearchMatch m) {
        for (ASTNode n = NodeFinder.perform(ast, m.getOffset(), m.getLength()); n != null; n = n.getParent()) {
            SimpleName name = n instanceof MethodInvocation mi ? mi.getName()
                    : n instanceof SuperMethodInvocation si ? si.getName() : null;
            if (name != null && name.getStartPosition() == m.getOffset()) {
                return n;
            }
            if (n instanceof BodyDeclaration) {
                return null;
            }
        }
        return null;
    }

    private static long stamp(ICompilationUnit cu) {
        IResource r = cu.getResource();
        return r == null ? -1 : r.getModificationStamp();
    }

    // ---- code -> core -------------------------------------------------------------------

    private CallSite callSite(ICompilationUnit cu, CompilationUnit ast, MethodInvocation call, Set<String> deps) {
        Expression q = call.getExpression();
        ITypeBinding type = q == null ? null : q.resolveTypeBinding();
        List<Argument> args = new ArrayList<>();
        for (Object o : call.arguments()) {
            args.add(argument(cu, ast, (Expression) o, deps));
        }
        return new CallSite(call.getName().getIdentifier(), type == null ? null : typeName(type),
                q == null ? null : source(cu, q), args, enclosing(cu, ast, call, deps), lambda(cu, ast, call),
                location(cu, ast, call));
    }

    private Argument argument(ICompilationUnit cu, CompilationUnit ast, Expression e, Set<String> deps) {
        String text = source(cu, e);
        if (e instanceof MethodReference ref) {
            IMethodBinding b = ref.resolveMethodBinding();
            return Argument.methodReference(text, b == null ? null : method(b, deps));
        }
        if (e instanceof LambdaExpression) {
            return Argument.lambda(text, location(cu, ast, e));
        }
        Object value = e.resolveConstantExpressionValue();
        if (value != null) {
            boolean literal = e instanceof StringLiteral || e instanceof TextBlock || e instanceof NumberLiteral
                    || e instanceof CharacterLiteral || e instanceof BooleanLiteral;
            return Argument.constant(text, String.valueOf(value), literal, literal ? List.of() : constantRefs(e, deps));
        }
        String type = null;
        List<MethodRef> methods = new ArrayList<>();
        if (e instanceof TypeLiteral tl) {
            ITypeBinding t = tl.getType().resolveBinding();
            type = t == null ? null : typeName(t);
        } else if (e instanceof ClassInstanceCreation || e instanceof ThisExpression || e instanceof Name || e instanceof FieldAccess) {
            ITypeBinding t = e.resolveTypeBinding();
            if (t != null && !t.isPrimitive() && !"java.lang.String".equals(t.getQualifiedName())) {
                type = typeName(t);
                AnonymousClassDeclaration anon = e instanceof ClassInstanceCreation c ? c.getAnonymousClassDeclaration() : null;
                if (anon != null) {
                    for (Object d : anon.bodyDeclarations()) {
                        if (d instanceof MethodDeclaration md && md.resolveBinding() != null) {
                            methods.add(method(md.resolveBinding(), deps));
                        }
                    }
                } else {
                    for (ITypeBinding c = t.getErasure(); c != null && isSource(c); c = c.getSuperclass()) {
                        for (IMethodBinding m : c.getDeclaredMethods()) {
                            if (!m.isConstructor()) {
                                methods.add(method(m, deps));
                            }
                        }
                    }
                }
            }
        }
        return Argument.other(text, pattern(e), type, methods);
    }

    /**
     * The known parts of a String built at run time ({@code "/orders/" + id} gives {@code "/orders/{}"}),
     * or null when no part is known.
     */
    private static String pattern(Expression e) {
        if (!(e instanceof InfixExpression ie) || ie.getOperator() != InfixExpression.Operator.PLUS) {
            return null;
        }
        List<Expression> parts = new ArrayList<>();
        parts.add(ie.getLeftOperand());
        parts.add(ie.getRightOperand());
        for (Object o : ie.extendedOperands()) {
            parts.add((Expression) o);
        }
        StringBuilder sb = new StringBuilder();
        boolean known = false;
        for (Expression p : parts) {
            while (p instanceof ParenthesizedExpression pe) {
                p = pe.getExpression();
            }
            Object v = p.resolveConstantExpressionValue();
            if (v != null) {
                sb.append(v);
                known = true;
            } else {
                String sub = pattern(p);
                sb.append(sub == null ? "{}" : sub);
                known |= sub != null;
            }
        }
        return known ? sb.toString() : null;
    }

    /** The String constants an expression goes through: the one written first, then the aliases followed. */
    private List<ConstantRef> constantRefs(Expression e, Set<String> deps) {
        IBinding b = e instanceof Name n ? n.resolveBinding() : e instanceof FieldAccess f ? f.resolveFieldBinding() : null;
        if (!(b instanceof IVariableBinding vb) || !vb.isField() || !(vb.getJavaElement() instanceof IField field)) {
            return List.of();
        }
        List<ConstantRef> out = new ArrayList<>();
        Set<IField> seen = new HashSet<>();
        while (field != null && seen.add(field) && out.size() < 10) {
            IType owner = field.getDeclaringType();
            out.add(new ConstantRef(owner.getElementName() + "." + field.getElementName(), declaration(field, deps)));
            field = aliasTarget(field);
        }
        return out;
    }

    /** For {@code String A = Other.B;}: the field B; else null. */
    private static IField aliasTarget(IField field) {
        try {
            String src = field.isBinary() ? null : field.getSource();
            Matcher m = src == null ? null : ALIAS_INIT.matcher(src);
            if (m == null || !m.find()) {
                return null;
            }
            String ref = m.group(1);
            IType owner = field.getDeclaringType();
            int dot = ref.lastIndexOf('.');
            if (dot < 0) {
                IField f = owner.getField(ref);
                return f.exists() ? f : null;
            }
            String typeName = ref.substring(0, dot), fieldName = ref.substring(dot + 1);
            String[][] resolved = owner.resolveType(typeName);
            if (resolved == null || resolved.length == 0) {
                return null;
            }
            String fq = resolved[0][0].isEmpty() ? resolved[0][1] : resolved[0][0] + "." + resolved[0][1];
            IType t = owner.getJavaProject().findType(fq);
            IField f = t == null ? null : t.getField(fieldName);
            return f != null && f.exists() ? f : null;
        } catch (JavaModelException e) {
            return null;
        }
    }

    private List<AnnotatedMethod.Annotation> annotations(ICompilationUnit cu, CompilationUnit ast, BodyDeclaration d, Set<String> deps) {
        List<AnnotatedMethod.Annotation> out = new ArrayList<>();
        for (Object o : d.modifiers()) {
            if (!(o instanceof org.eclipse.jdt.core.dom.Annotation a)) {
                continue;
            }
            Map<String, List<Argument>> values = new LinkedHashMap<>();
            if (a instanceof SingleMemberAnnotation s) {
                values.put("value", values(cu, ast, s.getValue(), deps));
            } else if (a instanceof NormalAnnotation n) {
                for (Object p : n.values()) {
                    MemberValuePair pair = (MemberValuePair) p;
                    values.put(pair.getName().getIdentifier(), values(cu, ast, pair.getValue(), deps));
                }
            }
            String name = a.getTypeName().getFullyQualifiedName();
            out.add(new AnnotatedMethod.Annotation(name.substring(name.lastIndexOf('.') + 1), values));
        }
        return out;
    }

    private List<Argument> values(ICompilationUnit cu, CompilationUnit ast, Expression v, Set<String> deps) {
        List<Argument> out = new ArrayList<>();
        if (v instanceof ArrayInitializer arr) {
            for (Object o : arr.expressions()) {
                out.add(argument(cu, ast, (Expression) o, deps));
            }
        } else {
            out.add(argument(cu, ast, v, deps));
        }
        return out;
    }

    private static String firstParamType(MethodDeclaration md) {
        if (md.parameters().isEmpty()) {
            return null;
        }
        SingleVariableDeclaration p = (SingleVariableDeclaration) md.parameters().get(0);
        ITypeBinding t = p.getType().resolveBinding();
        if (t != null && !t.isRecovered()) {
            return t.getErasure().getName();
        }
        String s = p.getType().toString().replaceAll("<.*", "");
        return s.substring(s.lastIndexOf('.') + 1);
    }

    /** The method a node is written in, or null (field initialiser, static block...). */
    private MethodRef enclosing(ICompilationUnit cu, CompilationUnit ast, ASTNode node, Set<String> deps) {
        for (ASTNode n = node.getParent(); n != null; n = n.getParent()) {
            if (n instanceof MethodDeclaration md) {
                return methodRef(cu, ast, md, deps);
            }
            if (n instanceof AbstractTypeDeclaration || n instanceof AnonymousClassDeclaration) {
                return null;
            }
        }
        return null;
    }

    /** Start of the innermost lambda (inside the enclosing method) a node is written in, or null. */
    private SourceLocation lambda(ICompilationUnit cu, CompilationUnit ast, ASTNode node) {
        for (ASTNode n = node.getParent(); n != null && !(n instanceof MethodDeclaration); n = n.getParent()) {
            if (n instanceof LambdaExpression) {
                return location(cu, ast, n);
            }
        }
        return null;
    }

    private MethodRef methodRef(ICompilationUnit cu, CompilationUnit ast, MethodDeclaration md, Set<String> deps) {
        IMethodBinding b = md.resolveBinding();
        if (b != null) {
            return method(b, deps);
        }
        String owner = md.getParent() instanceof AbstractTypeDeclaration t ? t.getName().getIdentifier() : "?";
        return new MethodRef(owner, owner, md.getName().getIdentifier(), location(cu, ast, md.getName()));
    }

    private MethodRef method(IMethodBinding b, Set<String> deps) {
        b = b.getMethodDeclaration();
        ITypeBinding c = b.getDeclaringClass().getErasure();
        String simple = c.getName().isEmpty() ? simpleOfBinary(c) : c.getName();
        return new MethodRef(typeName(c), simple, b.getName(), declaration(b.getJavaElement(), deps));
    }

    /** Qualified name; for anonymous and local classes the binary name ({@code com.shop.Foo$1}). */
    private static String typeName(ITypeBinding t) {
        ITypeBinding e = t.getErasure();
        if (!e.getQualifiedName().isEmpty()) {
            return e.getQualifiedName();
        }
        return e.getBinaryName() != null ? e.getBinaryName() : e.getName();
    }

    private static String simpleOfBinary(ITypeBinding t) {
        String b = t.getBinaryName();
        return b == null ? "?" : b.substring(b.lastIndexOf('.') + 1);
    }

    private static boolean isSource(ITypeBinding t) {
        return t.getJavaElement() instanceof IType type && !type.isBinary();
    }

    /** Where a member is declared, or null for one from a library; adds its file to deps. */
    private SourceLocation declaration(IJavaElement element, Set<String> deps) {
        if (!(element instanceof IMember member) || member.isBinary()) {
            return null;
        }
        ICompilationUnit cu = member.getCompilationUnit();
        try {
            ISourceRange range = member.getNameRange();
            if (cu == null || range == null || range.getOffset() < 0) {
                return null;
            }
            String file = relative(cu.getResource());
            if (file == null) {
                return null;
            }
            deps.add(file);
            return new SourceLocation(file, lineOf(cu, range.getOffset()));
        } catch (JavaModelException e) {
            return null;
        }
    }

    private SourceLocation location(ICompilationUnit cu, CompilationUnit ast, ASTNode node) {
        String file = relative(cu.getResource());
        return file == null ? null : new SourceLocation(file, ast.getLineNumber(node.getStartPosition()));
    }

    private static String source(ICompilationUnit cu, ASTNode node) {
        try {
            String src = cu.getSource();
            if (src != null && node.getStartPosition() >= 0 && node.getStartPosition() + node.getLength() <= src.length()) {
                return src.substring(node.getStartPosition(), node.getStartPosition() + node.getLength());
            }
        } catch (JavaModelException ignored) {
            // fall back to the AST's rendering
        }
        return node.toString();
    }

    /** Path relative to the root, or the absolute path when the file is outside it. */
    String relative(IResource r) {
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

    /** Ids of the methods around an offset of a file, innermost first, as core names them. */
    static List<String> methodIdsAt(ICompilationUnit cu, int offset) {
        List<String> out = new ArrayList<>();
        try {
            for (IJavaElement e = cu.getElementAt(offset); e != null; e = e.getParent()) {
                if (e instanceof IMethod m) {
                    out.add(m.getDeclaringType().getFullyQualifiedName('.') + "#" + m.getElementName());
                }
            }
        } catch (JavaModelException ignored) {
            // file not parsable right now
        }
        return out;
    }
}
