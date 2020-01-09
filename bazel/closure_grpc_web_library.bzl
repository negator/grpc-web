# This rule was inspired by rules_closure`s implementation of
# |closure_proto_library|, licensed under Apache 2.
# https://github.com/bazelbuild/rules_closure/blob/3555e5ba61fdcc17157dd833eaf7d19b313b1bca/closure/protobuf/closure_proto_library.bzl

load(
    "@io_bazel_rules_closure//closure/compiler:closure_js_library.bzl",
    "create_closure_js_library",
)
load(
    "@io_bazel_rules_closure//closure/private:defs.bzl",
    "CLOSURE_JS_TOOLCHAIN_ATTRS",
    "unfurl",
)
load(
    "@io_bazel_rules_closure//closure/protobuf:closure_proto_library.bzl",
    "closure_proto_aspect",
)

# This was borrowed from Rules Go, licensed under Apache 2.
# https://github.com/bazelbuild/rules_go/blob/67f44035d84a352cffb9465159e199066ecb814c/proto/compiler.bzl#L72
def _proto_path(proto):
    path = proto.path
    root = proto.root.path
    ws = proto.owner.workspace_root
    if path.startswith(root):
        path = path[len(root):]
    if path.startswith("/"):
        path = path[1:]
    if path.startswith(ws):
        path = path[len(ws):]
    if path.startswith("/"):
        path = path[1:]
    return path

def _proto_include_path(proto):
    path = proto.path[:-len(_proto_path(proto))]
    if not path:
        return "."
    if path.endswith("/"):
        path = path[:-1]
    return path

def _proto_include_paths(protos):
    return [_proto_include_path(proto) for proto in protos]

def _generate_closure_grpc_web_src_progress_message(name):
    # TODO(yannic): Add a better message?
    return "Generating GRPC Web %s" % name

def _generate_closure_grpc_web_srcs(
        actions,
        protoc,
        protoc_gen_grpc_web,
        import_style,
        mode,
        sources,
        transitive_sources):
    all_sources = [src for src in sources] + [src for src in transitive_sources.to_list()]
    proto_include_paths = [
        "-I%s" % p
        for p in _proto_include_paths(
            [f for f in all_sources],
        )
    ]

    grpc_web_out_common_options = ",".join([
        "import_style={}".format(import_style),
        "mode={}".format(mode),
    ])

    files = []
    for src in sources:
        name = "{}.grpc.js".format(
            ".".join(src.path.split("/")[-1].split(".")[:-1]),
        )
        js = actions.declare_file(name)
        files.append(js)

        args = proto_include_paths + [
            "--plugin=protoc-gen-grpc-web={}".format(protoc_gen_grpc_web.path),
            "--grpc-web_out={options},out={out_file}:{path}".format(
                options = grpc_web_out_common_options,
                out_file = name,
                path = js.path[:js.path.rfind("/")],
            ),
            src.path,
        ]

        actions.run(
            tools = [protoc_gen_grpc_web],
            inputs = all_sources,
            outputs = [js],
            executable = protoc,
            arguments = args,
            progress_message =
                _generate_closure_grpc_web_src_progress_message(name),
        )

    return files

_error_multiple_deps = "".join([
    "'deps' attribute must contain exactly one label ",
    "(we didn't name it 'dep' for consistency). ",
    "We may revisit this restriction later.",
])

def _closure_grpc_web_library_impl(ctx):
    if len(ctx.attr.deps) > 1:
        # TODO(yannic): Revisit this restriction.
        fail(_error_multiple_deps, "deps")

    dep = ctx.attr.deps[0]

    srcs = _generate_closure_grpc_web_srcs(
        actions = ctx.actions,
        protoc = ctx.executable._protoc,
        protoc_gen_grpc_web = ctx.executable._protoc_gen_grpc_web,
        import_style = ctx.attr.import_style,
        mode = ctx.attr.mode,
        sources = dep[ProtoInfo].direct_sources,
        transitive_sources = dep[ProtoInfo].transitive_imports,
    )

    deps = unfurl(ctx.attr.deps, provider = "closure_js_library")
    deps += [
        ctx.attr._grpc_web_abstractclientbase,
        ctx.attr._grpc_web_clientreadablestream,
        ctx.attr._grpc_web_error,
        ctx.attr._grpc_web_grpcwebclientbase,
    ]

    suppress = [
        "misplacedTypeAnnotation",
        "unusedPrivateMembers",
        "reportUnknownTypes",
        "strictDependencies",
        "extraRequire",
        "superfluousSuppress,
    ]

    library = create_closure_js_library(
        ctx = ctx,
        srcs = srcs,
        deps = deps,
        suppress = suppress,
        lenient = False,
    )
    return struct(
        exports = library.exports,
        closure_js_library = library.closure_js_library,
        # The usual suspects are exported as runfiles, in addition to raw source.
        runfiles = ctx.runfiles(files = srcs),
    )

closure_grpc_web_library = rule(
    implementation = _closure_grpc_web_library_impl,
    attrs = dict({
        "deps": attr.label_list(
            mandatory = True,
            providers = [ProtoInfo, "closure_js_library"],
            # The files generated by this aspect are required dependencies.
            aspects = [closure_proto_aspect],
        ),
        "import_style": attr.string(
            default = "closure",
            values = ["closure", "commonjs"],
        ),
        "mode": attr.string(
            default = "grpcwebtext",
            values = ["grpcwebtext", "grpcweb"],
        ),

        # internal only
        # TODO(yannic): Convert to toolchain.
        "_protoc": attr.label(
            default = Label("@com_google_protobuf//:protoc"),
            executable = True,
            cfg = "host",
        ),
        "_protoc_gen_grpc_web": attr.label(
            default = Label("//javascript/net/grpc/web:protoc-gen-grpc-web"),
            executable = True,
            cfg = "host",
        ),
        "_grpc_web_abstractclientbase": attr.label(
            default = Label("//javascript/net/grpc/web:abstractclientbase"),
        ),
        "_grpc_web_clientreadablestream": attr.label(
            default = Label("//javascript/net/grpc/web:clientreadablestream"),
        ),
        "_grpc_web_error": attr.label(
            default = Label("//javascript/net/grpc/web:error"),
        ),
        "_grpc_web_grpcwebclientbase": attr.label(
            default = Label("//javascript/net/grpc/web:grpcwebclientbase"),
        ),
    }, **CLOSURE_JS_TOOLCHAIN_ATTRS),
)
