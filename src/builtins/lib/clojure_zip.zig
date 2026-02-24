// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.zip — Functional hierarchical zipper.
//! Replaces clojure/zip.clj. See Huet.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../../runtime/value.zig");
const Value = value_mod.Value;
const var_mod = @import("../../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const errmod = @import("../../runtime/error.zig");
const bootstrap = @import("../../runtime/bootstrap.zig");
const dispatch = @import("../../runtime/dispatch.zig");
const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;

fn callCore(allocator: Allocator, name: []const u8, args: []const Value) !Value {
    const env = dispatch.macro_eval_env orelse return error.EvalError;
    const core_ns = env.findNamespace("clojure.core") orelse return error.EvalError;
    const v = core_ns.mappings.get(name) orelse return error.EvalError;
    return bootstrap.callFnVal(allocator, v.deref(), args);
}

fn resolveCoreFn(name: []const u8) !Value {
    const env = dispatch.macro_eval_env orelse return error.EvalError;
    const core_ns = env.findNamespace("clojure.core") orelse return error.EvalError;
    const v = core_ns.mappings.get(name) orelse return error.EvalError;
    return v.deref();
}

fn kw(allocator: Allocator, name: []const u8) Value {
    return Value.initKeyword(allocator, .{ .ns = null, .name = name });
}

fn kwNs(allocator: Allocator, ns: []const u8, name: []const u8) Value {
    return Value.initKeyword(allocator, .{ .ns = ns, .name = name });
}

// -- Core zipper functions --

/// (zipper branch? children make-node root)
fn zipperFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 4) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to zipper", .{args.len});
    const branch_fn = args[0];
    const children_fn = args[1];
    const make_node_fn = args[2];
    const root = args[3];

    // Build metadata map: {:zip/branch? f, :zip/children f, :zip/make-node f}
    const meta_map = try callCore(allocator, "hash-map", &.{
        kwNs(allocator, "zip", "branch?"),  branch_fn,
        kwNs(allocator, "zip", "children"), children_fn,
        kwNs(allocator, "zip", "make-node"), make_node_fn,
    });

    // Build [root nil] with metadata
    const vec = try callCore(allocator, "vector", &.{ root, Value.nil_val });
    return callCore(allocator, "with-meta", &.{ vec, meta_map });
}

/// Helper for seq-zip make-node: (fn [node children] (with-meta children (meta node)))
fn seqZipMakeNodeFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args", .{});
    const node = args[0];
    const children = args[1];
    const m = try callCore(allocator, "meta", &.{node});
    return callCore(allocator, "with-meta", &.{ children, m });
}

/// (seq-zip root)
fn seqZipFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to seq-zip", .{args.len});
    const seq_q = try resolveCoreFn("seq?");
    const identity = try resolveCoreFn("identity");
    const make_node = Value.initBuiltinFn(&seqZipMakeNodeFn);
    return zipperFn(allocator, &.{ seq_q, identity, make_node, args[0] });
}

/// Helper for vector-zip make-node: (fn [node children] (with-meta (vec children) (meta node)))
fn vectorZipMakeNodeFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args", .{});
    const node = args[0];
    const children = args[1];
    const v = try callCore(allocator, "vec", &.{children});
    const m = try callCore(allocator, "meta", &.{node});
    return callCore(allocator, "with-meta", &.{ v, m });
}

/// (vector-zip root)
fn vectorZipFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to vector-zip", .{args.len});
    const vector_q = try resolveCoreFn("vector?");
    const seq_fn = try resolveCoreFn("seq");
    const make_node = Value.initBuiltinFn(&vectorZipMakeNodeFn);
    return zipperFn(allocator, &.{ vector_q, seq_fn, make_node, args[0] });
}

/// Helper for xml-zip make-node: (fn [node children] (assoc node :content (and children (apply vector children))))
fn xmlZipMakeNodeFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args", .{});
    const node = args[0];
    const children = args[1];
    const content = if (children.isTruthy()) blk: {
        const vector_fn = try resolveCoreFn("vector");
        break :blk try callCore(allocator, "apply", &.{ vector_fn, children });
    } else Value.nil_val;
    return callCore(allocator, "assoc", &.{ node, kw(allocator, "content"), content });
}

/// (xml-zip root)
fn xmlZipFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to xml-zip", .{args.len});
    // (complement string?)
    const string_q = try resolveCoreFn("string?");
    const branch_fn = try callCore(allocator, "complement", &.{string_q});
    // (comp seq :content)
    const seq_fn = try resolveCoreFn("seq");
    const content_kw = kw(allocator, "content");
    const children_fn = try callCore(allocator, "comp", &.{ seq_fn, content_kw });
    const make_node = Value.initBuiltinFn(&xmlZipMakeNodeFn);
    return zipperFn(allocator, &.{ branch_fn, children_fn, make_node, args[0] });
}

// -- Navigation functions --

/// (node loc) -> (loc 0)
fn nodeFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to node", .{args.len});
    return callCore(allocator, "nth", &.{ args[0], Value.initInteger(0) });
}

/// (branch? loc)
fn branchQFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to branch?", .{args.len});
    const loc = args[0];
    const m = try callCore(allocator, "meta", &.{loc});
    const branch_fn = try callCore(allocator, "get", &.{ m, kwNs(allocator, "zip", "branch?") });
    const n = try nodeFn(allocator, &.{loc});
    return bootstrap.callFnVal(allocator, branch_fn, &.{n});
}

/// (children loc)
fn childrenFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to children", .{args.len});
    const loc = args[0];
    const is_branch = try branchQFn(allocator, &.{loc});
    if (is_branch.isTruthy()) {
        const m = try callCore(allocator, "meta", &.{loc});
        const children_fn = try callCore(allocator, "get", &.{ m, kwNs(allocator, "zip", "children") });
        const n = try nodeFn(allocator, &.{loc});
        return bootstrap.callFnVal(allocator, children_fn, &.{n});
    }
    return errmod.setErrorFmt(.eval, .value_error, .{}, "called children on a leaf node", .{});
}

/// (make-node loc node children)
fn makeNodeFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to make-node", .{args.len});
    const loc = args[0];
    const m = try callCore(allocator, "meta", &.{loc});
    const mn_fn = try callCore(allocator, "get", &.{ m, kwNs(allocator, "zip", "make-node") });
    return bootstrap.callFnVal(allocator, mn_fn, &.{ args[1], args[2] });
}

/// (path loc)
fn pathFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to path", .{args.len});
    const path_map = try callCore(allocator, "nth", &.{ args[0], Value.initInteger(1) });
    return callCore(allocator, "get", &.{ path_map, kw(allocator, "pnodes") });
}

/// (lefts loc)
fn leftsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to lefts", .{args.len});
    const path_map = try callCore(allocator, "nth", &.{ args[0], Value.initInteger(1) });
    const l = try callCore(allocator, "get", &.{ path_map, kw(allocator, "l") });
    return callCore(allocator, "seq", &.{l});
}

/// (rights loc)
fn rightsFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to rights", .{args.len});
    const path_map = try callCore(allocator, "nth", &.{ args[0], Value.initInteger(1) });
    return callCore(allocator, "get", &.{ path_map, kw(allocator, "r") });
}

/// (down loc)
fn downFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to down", .{args.len});
    const loc = args[0];
    const is_branch = try branchQFn(allocator, &.{loc});
    if (!is_branch.isTruthy()) return Value.nil_val;

    const node = try nodeFn(allocator, &.{loc});
    const path_map = try callCore(allocator, "nth", &.{ loc, Value.initInteger(1) });
    const cs = try childrenFn(allocator, &.{loc});
    if (!cs.isTruthy()) return Value.nil_val;

    const c = try callCore(allocator, "first", &.{cs});
    const cnext = try callCore(allocator, "next", &.{cs});

    // Build path: {:l [] :pnodes (if path (conj (:pnodes path) node) [node]) :ppath path :r cnext}
    const pnodes = if (path_map.tag() != .nil) blk: {
        const existing = try callCore(allocator, "get", &.{ path_map, kw(allocator, "pnodes") });
        break :blk try callCore(allocator, "conj", &.{ existing, node });
    } else try callCore(allocator, "vector", &.{node});

    const new_path = try callCore(allocator, "hash-map", &.{
        kw(allocator, "l"),      try callCore(allocator, "vector", &.{}),
        kw(allocator, "pnodes"), pnodes,
        kw(allocator, "ppath"),  path_map,
        kw(allocator, "r"),      cnext,
    });

    const vec = try callCore(allocator, "vector", &.{ c, new_path });
    const m = try callCore(allocator, "meta", &.{loc});
    return callCore(allocator, "with-meta", &.{ vec, m });
}

/// (up loc)
fn upFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to up", .{args.len});
    const loc = args[0];
    const node = try callCore(allocator, "nth", &.{ loc, Value.initInteger(0) });
    const path_map = try callCore(allocator, "nth", &.{ loc, Value.initInteger(1) });

    if (path_map.tag() == .nil) return Value.nil_val;

    const pnodes = try callCore(allocator, "get", &.{ path_map, kw(allocator, "pnodes") });
    if (!pnodes.isTruthy()) return Value.nil_val;

    const l = try callCore(allocator, "get", &.{ path_map, kw(allocator, "l") });
    const r = try callCore(allocator, "get", &.{ path_map, kw(allocator, "r") });
    const ppath = try callCore(allocator, "get", &.{ path_map, kw(allocator, "ppath") });
    const changed = try callCore(allocator, "get", &.{ path_map, kw(allocator, "changed?") });
    const pnode = try callCore(allocator, "peek", &.{pnodes});

    const result = if (changed.isTruthy()) blk: {
        // [(make-node loc pnode (concat l (cons node r))) (and ppath (assoc ppath :changed? true))]
        const node_r = try callCore(allocator, "cons", &.{ node, r });
        const all_children = try callCore(allocator, "concat", &.{ l, node_r });
        const new_node = try makeNodeFn(allocator, &.{ loc, pnode, all_children });
        const new_ppath = if (ppath.isTruthy())
            try callCore(allocator, "assoc", &.{ ppath, kw(allocator, "changed?"), Value.true_val })
        else
            Value.nil_val;
        break :blk try callCore(allocator, "vector", &.{ new_node, new_ppath });
    } else try callCore(allocator, "vector", &.{ pnode, ppath });

    const m = try callCore(allocator, "meta", &.{loc});
    return callCore(allocator, "with-meta", &.{ result, m });
}

/// (root loc)
fn rootFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to root", .{args.len});
    var loc = args[0];
    // Check for :end
    const loc1 = try callCore(allocator, "nth", &.{ loc, Value.initInteger(1) });
    const is_end = try callCore(allocator, "=", &.{ loc1, kw(allocator, "end") });
    if (is_end.isTruthy()) return nodeFn(allocator, &.{loc});

    // Loop: go up until no parent
    while (true) {
        const p = try upFn(allocator, &.{loc});
        if (!p.isTruthy()) return nodeFn(allocator, &.{loc});
        loc = p;
    }
}

/// (right loc)
fn rightFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to right", .{args.len});
    const loc = args[0];
    const node = try callCore(allocator, "nth", &.{ loc, Value.initInteger(0) });
    const path_map = try callCore(allocator, "nth", &.{ loc, Value.initInteger(1) });
    if (path_map.tag() == .nil) return Value.nil_val;

    const rs = try callCore(allocator, "get", &.{ path_map, kw(allocator, "r") });
    if (!rs.isTruthy()) return Value.nil_val;

    const l = try callCore(allocator, "get", &.{ path_map, kw(allocator, "l") });
    const r = try callCore(allocator, "first", &.{rs});
    const rnext = try callCore(allocator, "next", &.{rs});
    const new_l = try callCore(allocator, "conj", &.{ l, node });
    const new_path = try callCore(allocator, "assoc", &.{ path_map, kw(allocator, "l"), new_l, kw(allocator, "r"), rnext });

    const vec = try callCore(allocator, "vector", &.{ r, new_path });
    const m = try callCore(allocator, "meta", &.{loc});
    return callCore(allocator, "with-meta", &.{ vec, m });
}

/// (rightmost loc)
fn rightmostFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to rightmost", .{args.len});
    const loc = args[0];
    const node = try callCore(allocator, "nth", &.{ loc, Value.initInteger(0) });
    const path_map = try callCore(allocator, "nth", &.{ loc, Value.initInteger(1) });
    if (path_map.tag() == .nil) return loc;

    const r = try callCore(allocator, "get", &.{ path_map, kw(allocator, "r") });
    if (!r.isTruthy()) return loc;

    const l = try callCore(allocator, "get", &.{ path_map, kw(allocator, "l") });
    const last_r = try callCore(allocator, "last", &.{r});
    // (apply conj l node (butlast r))
    const butlast_r = try callCore(allocator, "butlast", &.{r});
    var new_l = try callCore(allocator, "conj", &.{ l, node });
    if (butlast_r.isTruthy()) {
        const conj_fn = try resolveCoreFn("conj");
        new_l = try callCore(allocator, "apply", &.{ conj_fn, new_l, butlast_r });
    }
    const new_path = try callCore(allocator, "assoc", &.{ path_map, kw(allocator, "l"), new_l, kw(allocator, "r"), Value.nil_val });

    const vec = try callCore(allocator, "vector", &.{ last_r, new_path });
    const m = try callCore(allocator, "meta", &.{loc});
    return callCore(allocator, "with-meta", &.{ vec, m });
}

/// (left loc)
fn leftFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to left", .{args.len});
    const loc = args[0];
    const node = try callCore(allocator, "nth", &.{ loc, Value.initInteger(0) });
    const path_map = try callCore(allocator, "nth", &.{ loc, Value.initInteger(1) });
    if (path_map.tag() == .nil) return Value.nil_val;

    const l = try callCore(allocator, "get", &.{ path_map, kw(allocator, "l") });
    const l_seq = try callCore(allocator, "seq", &.{l});
    if (!l_seq.isTruthy()) return Value.nil_val;

    const r = try callCore(allocator, "get", &.{ path_map, kw(allocator, "r") });
    const top = try callCore(allocator, "peek", &.{l});
    const new_l = try callCore(allocator, "pop", &.{l});
    const new_r = try callCore(allocator, "cons", &.{ node, r });
    const new_path = try callCore(allocator, "assoc", &.{ path_map, kw(allocator, "l"), new_l, kw(allocator, "r"), new_r });

    const vec = try callCore(allocator, "vector", &.{ top, new_path });
    const m = try callCore(allocator, "meta", &.{loc});
    return callCore(allocator, "with-meta", &.{ vec, m });
}

/// (leftmost loc)
fn leftmostFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to leftmost", .{args.len});
    const loc = args[0];
    const node = try callCore(allocator, "nth", &.{ loc, Value.initInteger(0) });
    const path_map = try callCore(allocator, "nth", &.{ loc, Value.initInteger(1) });
    if (path_map.tag() == .nil) return loc;

    const l = try callCore(allocator, "get", &.{ path_map, kw(allocator, "l") });
    const l_seq = try callCore(allocator, "seq", &.{l});
    if (!l_seq.isTruthy()) return loc;

    const r = try callCore(allocator, "get", &.{ path_map, kw(allocator, "r") });
    const first_l = try callCore(allocator, "first", &.{l});
    // (concat (rest l) [node] r)
    const rest_l = try callCore(allocator, "rest", &.{l});
    const node_vec = try callCore(allocator, "vector", &.{node});
    const new_r = try callCore(allocator, "concat", &.{ rest_l, node_vec, r });
    const new_path = try callCore(allocator, "assoc", &.{ path_map, kw(allocator, "l"), try callCore(allocator, "vector", &.{}), kw(allocator, "r"), new_r });

    const vec = try callCore(allocator, "vector", &.{ first_l, new_path });
    const m = try callCore(allocator, "meta", &.{loc});
    return callCore(allocator, "with-meta", &.{ vec, m });
}

// -- Editing functions --

/// (insert-left loc item)
fn insertLeftFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to insert-left", .{args.len});
    const loc = args[0];
    const item = args[1];
    const node = try callCore(allocator, "nth", &.{ loc, Value.initInteger(0) });
    const path_map = try callCore(allocator, "nth", &.{ loc, Value.initInteger(1) });
    if (path_map.tag() == .nil) return errmod.setErrorFmt(.eval, .value_error, .{}, "Insert at top", .{});

    const l = try callCore(allocator, "get", &.{ path_map, kw(allocator, "l") });
    const new_l = try callCore(allocator, "conj", &.{ l, item });
    const new_path = try callCore(allocator, "assoc", &.{ path_map, kw(allocator, "l"), new_l, kw(allocator, "changed?"), Value.true_val });
    const vec = try callCore(allocator, "vector", &.{ node, new_path });
    const m = try callCore(allocator, "meta", &.{loc});
    return callCore(allocator, "with-meta", &.{ vec, m });
}

/// (insert-right loc item)
fn insertRightFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to insert-right", .{args.len});
    const loc = args[0];
    const item = args[1];
    const node = try callCore(allocator, "nth", &.{ loc, Value.initInteger(0) });
    const path_map = try callCore(allocator, "nth", &.{ loc, Value.initInteger(1) });
    if (path_map.tag() == .nil) return errmod.setErrorFmt(.eval, .value_error, .{}, "Insert at top", .{});

    const r = try callCore(allocator, "get", &.{ path_map, kw(allocator, "r") });
    const new_r = try callCore(allocator, "cons", &.{ item, r });
    const new_path = try callCore(allocator, "assoc", &.{ path_map, kw(allocator, "r"), new_r, kw(allocator, "changed?"), Value.true_val });
    const vec = try callCore(allocator, "vector", &.{ node, new_path });
    const m = try callCore(allocator, "meta", &.{loc});
    return callCore(allocator, "with-meta", &.{ vec, m });
}

/// (replace loc node)
fn replaceFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to replace", .{args.len});
    const loc = args[0];
    const node = args[1];
    const path_map = try callCore(allocator, "nth", &.{ loc, Value.initInteger(1) });
    const new_path = try callCore(allocator, "assoc", &.{ path_map, kw(allocator, "changed?"), Value.true_val });
    const vec = try callCore(allocator, "vector", &.{ node, new_path });
    const m = try callCore(allocator, "meta", &.{loc});
    return callCore(allocator, "with-meta", &.{ vec, m });
}

/// (edit loc f & args) -> (replace loc (apply f (node loc) args))
fn editFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to edit", .{args.len});
    const loc = args[0];
    const f = args[1];
    const n = try nodeFn(allocator, &.{loc});

    // Build args list: (node rest-args...)
    var fn_args = std.ArrayList(Value).empty;
    fn_args.append(allocator, n) catch return error.EvalError;
    for (args[2..]) |a| {
        fn_args.append(allocator, a) catch return error.EvalError;
    }

    const result = try bootstrap.callFnVal(allocator, f, fn_args.items);
    return replaceFn(allocator, &.{ loc, result });
}

/// (insert-child loc item)
fn insertChildFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to insert-child", .{args.len});
    const loc = args[0];
    const item = args[1];
    const n = try nodeFn(allocator, &.{loc});
    const cs = try childrenFn(allocator, &.{loc});
    const new_children = try callCore(allocator, "cons", &.{ item, cs });
    const new_node = try makeNodeFn(allocator, &.{ loc, n, new_children });
    return replaceFn(allocator, &.{ loc, new_node });
}

/// (append-child loc item)
fn appendChildFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to append-child", .{args.len});
    const loc = args[0];
    const item = args[1];
    const n = try nodeFn(allocator, &.{loc});
    const cs = try childrenFn(allocator, &.{loc});
    const item_vec = try callCore(allocator, "vector", &.{item});
    const new_children = try callCore(allocator, "concat", &.{ cs, item_vec });
    const new_node = try makeNodeFn(allocator, &.{ loc, n, new_children });
    return replaceFn(allocator, &.{ loc, new_node });
}

// -- Traversal functions --

/// (next loc) — depth-first traversal
fn nextFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to next", .{args.len});
    const loc = args[0];

    // Check :end
    const loc1 = try callCore(allocator, "nth", &.{ loc, Value.initInteger(1) });
    const is_end = try callCore(allocator, "=", &.{ loc1, kw(allocator, "end") });
    if (is_end.isTruthy()) return loc;

    // Try: (and (branch? loc) (down loc))
    const is_branch = try branchQFn(allocator, &.{loc});
    if (is_branch.isTruthy()) {
        const d = try downFn(allocator, &.{loc});
        if (d.isTruthy()) return d;
    }

    // Try: (right loc)
    const r = try rightFn(allocator, &.{loc});
    if (r.isTruthy()) return r;

    // Loop up until we can go right
    var p = loc;
    while (true) {
        const parent = try upFn(allocator, &.{p});
        if (!parent.isTruthy()) {
            // At top — return [node :end]
            const n = try nodeFn(allocator, &.{p});
            return callCore(allocator, "vector", &.{ n, kw(allocator, "end") });
        }
        const right_of_parent = try rightFn(allocator, &.{parent});
        if (right_of_parent.isTruthy()) return right_of_parent;
        p = parent;
    }
}

/// (prev loc)
fn prevFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to prev", .{args.len});
    const loc = args[0];

    const lloc = try leftFn(allocator, &.{loc});
    if (lloc.isTruthy()) {
        // Go to rightmost leaf of left sibling
        var current = lloc;
        while (true) {
            const is_branch = try branchQFn(allocator, &.{current});
            if (!is_branch.isTruthy()) return current;
            const child = try downFn(allocator, &.{current});
            if (!child.isTruthy()) return current;
            current = try rightmostFn(allocator, &.{child});
        }
    }
    return upFn(allocator, &.{loc});
}

/// (end? loc)
fn endQFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to end?", .{args.len});
    const loc1 = try callCore(allocator, "nth", &.{ args[0], Value.initInteger(1) });
    return callCore(allocator, "=", &.{ loc1, kw(allocator, "end") });
}

/// (remove loc)
fn removeFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to remove", .{args.len});
    const loc = args[0];
    const path_map = try callCore(allocator, "nth", &.{ loc, Value.initInteger(1) });
    if (path_map.tag() == .nil) return errmod.setErrorFmt(.eval, .value_error, .{}, "Remove at top", .{});

    const l = try callCore(allocator, "get", &.{ path_map, kw(allocator, "l") });
    const ppath = try callCore(allocator, "get", &.{ path_map, kw(allocator, "ppath") });
    const pnodes = try callCore(allocator, "get", &.{ path_map, kw(allocator, "pnodes") });
    const rs = try callCore(allocator, "get", &.{ path_map, kw(allocator, "r") });

    const l_count = try callCore(allocator, "count", &.{l});
    const cnt = l_count.asInteger();

    const m = try callCore(allocator, "meta", &.{loc});

    if (cnt > 0) {
        // Walk to rightmost leaf of left sibling
        const top = try callCore(allocator, "peek", &.{l});
        const new_l = try callCore(allocator, "pop", &.{l});
        const new_path = try callCore(allocator, "assoc", &.{ path_map, kw(allocator, "l"), new_l, kw(allocator, "changed?"), Value.true_val });
        var current = try callCore(allocator, "vector", &.{ top, new_path });
        current = try callCore(allocator, "with-meta", &.{ current, m });

        while (true) {
            const is_branch = try branchQFn(allocator, &.{current});
            if (!is_branch.isTruthy()) return current;
            const child = try downFn(allocator, &.{current});
            if (!child.isTruthy()) return current;
            current = try rightmostFn(allocator, &.{child});
        }
    } else {
        const pnode = try callCore(allocator, "peek", &.{pnodes});
        const new_node = try makeNodeFn(allocator, &.{ loc, pnode, rs });
        const new_ppath = if (ppath.isTruthy())
            try callCore(allocator, "assoc", &.{ ppath, kw(allocator, "changed?"), Value.true_val })
        else
            Value.nil_val;
        const vec = try callCore(allocator, "vector", &.{ new_node, new_ppath });
        return callCore(allocator, "with-meta", &.{ vec, m });
    }
}

// ============================================================
// Namespace definition
// ============================================================

const builtins = [_]BuiltinDef{
    .{ .name = "zipper", .func = &zipperFn, .doc = "Creates a new zipper structure." },
    .{ .name = "seq-zip", .func = &seqZipFn, .doc = "Returns a zipper for nested sequences." },
    .{ .name = "vector-zip", .func = &vectorZipFn, .doc = "Returns a zipper for nested vectors." },
    .{ .name = "xml-zip", .func = &xmlZipFn, .doc = "Returns a zipper for xml elements." },
    .{ .name = "node", .func = &nodeFn, .doc = "Returns the node at loc." },
    .{ .name = "branch?", .func = &branchQFn, .doc = "Returns true if the node at loc is a branch." },
    .{ .name = "children", .func = &childrenFn, .doc = "Returns a seq of the children of node at loc." },
    .{ .name = "make-node", .func = &makeNodeFn, .doc = "Returns a new branch node." },
    .{ .name = "path", .func = &pathFn, .doc = "Returns a seq of nodes leading to this loc." },
    .{ .name = "lefts", .func = &leftsFn, .doc = "Returns a seq of the left siblings of this loc." },
    .{ .name = "rights", .func = &rightsFn, .doc = "Returns a seq of the right siblings of this loc." },
    .{ .name = "down", .func = &downFn, .doc = "Returns the loc of the leftmost child." },
    .{ .name = "up", .func = &upFn, .doc = "Returns the loc of the parent." },
    .{ .name = "root", .func = &rootFn, .doc = "Zips all the way up and returns the root node." },
    .{ .name = "right", .func = &rightFn, .doc = "Returns the loc of the right sibling." },
    .{ .name = "rightmost", .func = &rightmostFn, .doc = "Returns the loc of the rightmost sibling." },
    .{ .name = "left", .func = &leftFn, .doc = "Returns the loc of the left sibling." },
    .{ .name = "leftmost", .func = &leftmostFn, .doc = "Returns the loc of the leftmost sibling." },
    .{ .name = "insert-left", .func = &insertLeftFn, .doc = "Inserts the item as the left sibling." },
    .{ .name = "insert-right", .func = &insertRightFn, .doc = "Inserts the item as the right sibling." },
    .{ .name = "replace", .func = &replaceFn, .doc = "Replaces the node at this loc." },
    .{ .name = "edit", .func = &editFn, .doc = "Replaces the node at this loc with the value of (f node args)." },
    .{ .name = "insert-child", .func = &insertChildFn, .doc = "Inserts the item as the leftmost child." },
    .{ .name = "append-child", .func = &appendChildFn, .doc = "Inserts the item as the rightmost child." },
    .{ .name = "next", .func = &nextFn, .doc = "Moves to the next loc in the hierarchy, depth-first." },
    .{ .name = "prev", .func = &prevFn, .doc = "Moves to the previous loc in the hierarchy." },
    .{ .name = "end?", .func = &endQFn, .doc = "Returns true if loc represents the end." },
    .{ .name = "remove", .func = &removeFn, .doc = "Removes the node at loc." },
};

pub const namespace_def = NamespaceDef{
    .name = "clojure.zip",
    .builtins = &builtins,
};
