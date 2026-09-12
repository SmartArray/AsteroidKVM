#!/usr/bin/env python3
# Generate a reviewable Xcode project without requiring a project-generator installation.
import hashlib
import json
import pathlib

root = pathlib.Path(__file__).resolve().parent.parent
objects = {}


# Derive stable object identifiers so regenerating the project produces reviewable diffs.
def oid(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


# Register typed project objects once and return their stable cross-reference identifiers.
def obj(label, isa, **values):
    key = oid(label)
    objects[key] = dict(isa=isa, **values)
    return key


# Keep debug and universal release settings consistent across app and test targets.
def config_list(name, settings):
    configs = []
    for variant in ["Debug", "Release"]:
        values = dict(settings)
        values.update(
            SWIFT_OPTIMIZATION_LEVEL="-Onone" if variant == "Debug" else "-O",
            DEBUG_INFORMATION_FORMAT=(
                "dwarf" if variant == "Debug" else "dwarf-with-dsym"
            ),
        )
        if variant == "Debug":
            values["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
            values["ONLY_ACTIVE_ARCH"] = "YES"
        configs.append(
            obj(
                name + variant,
                "XCBuildConfiguration",
                name=variant,
                buildSettings=values,
            )
        )
    return obj(
        name + "Configs",
        "XCConfigurationList",
        buildConfigurations=configs,
        defaultConfigurationIsVisible=0,
        defaultConfigurationName="Release",
    )


# Share implementation libraries through the same local Swift package used by command-line tests.
package = obj("LocalPackage", "XCLocalSwiftPackageReference", relativePath=".")
products = []
groups = []
targets = []
for name, source, kind, dependencies in [
    (
        "CometKVM",
        "Sources/CometApp",
        "com.apple.product-type.application",
        ["CometCore", "CometMedia", "CometAgent", "CometSession"],
    ),
    (
        "CometCoreTests",
        "Tests/CometCoreTests",
        "com.apple.product-type.bundle.unit-test",
        ["CometCore", "CometMedia", "CometAgent", "CometSession"],
    ),
    (
        "CometUITests",
        "Tests/CometUITests",
        "com.apple.product-type.bundle.ui-testing",
        [],
    ),
]:
    files = []
    build_files = []
    for path in sorted((root / source).glob("*.swift")):
        ref = obj(
            str(path.relative_to(root)),
            "PBXFileReference",
            lastKnownFileType="sourcecode.swift",
            path=str(path.relative_to(root)),
            sourceTree="<group>",
        )
        files.append(ref)
        build_files.append(obj(name + path.name, "PBXBuildFile", fileRef=ref))
    groups.append(
        obj(name + "Group", "PBXGroup", children=files, name=name, sourceTree="<group>")
    )
    ext = "app" if name == "CometKVM" else "xctest"
    product = obj(
        name + "Product",
        "PBXFileReference",
        explicitFileType="wrapper.application" if ext == "app" else "wrapper.cfbundle",
        path=name + "." + ext,
        sourceTree="BUILT_PRODUCTS_DIR",
    )
    products.append(product)
    package_dependencies = [
        obj(
            name + dep,
            "XCSwiftPackageProductDependency",
            package=package,
            productName=dep,
        )
        for dep in dependencies
    ]
    framework_files = [
        obj(name + dep + "Link", "PBXBuildFile", productRef=ref)
        for dep, ref in zip(dependencies, package_dependencies)
    ]
    sources = obj(
        name + "Sources",
        "PBXSourcesBuildPhase",
        buildActionMask=2147483647,
        files=build_files,
        runOnlyForDeploymentPostprocessing=0,
    )
    frameworks = obj(
        name + "Frameworks",
        "PBXFrameworksBuildPhase",
        buildActionMask=2147483647,
        files=framework_files,
        runOnlyForDeploymentPostprocessing=0,
    )
    # Ship dependency license notices inside the app so the binary carries its redistribution terms.
    phases = [sources, frameworks]
    if name == "CometKVM":
        notice = obj(
            "ThirdPartyNotices",
            "PBXFileReference",
            lastKnownFileType="text",
            path="Resources/ThirdPartyNotices.txt",
            sourceTree="<group>",
        )
        objects[groups[-1]]["children"].append(notice)
        notice_build = obj("ThirdPartyNoticesBuild", "PBXBuildFile", fileRef=notice)
        phases.append(
            obj(
                "AppResources",
                "PBXResourcesBuildPhase",
                buildActionMask=2147483647,
                files=[notice_build],
                runOnlyForDeploymentPostprocessing=0,
            )
        )
    settings = dict(
        PRODUCT_BUNDLE_IDENTIFIER="app.cometkvm." + name,
        PRODUCT_NAME="$(TARGET_NAME)",
        SWIFT_VERSION="5.0",
        MACOSX_DEPLOYMENT_TARGET="14.0",
        CODE_SIGN_IDENTITY="-",
        CODE_SIGN_STYLE="Automatic",
        GENERATE_INFOPLIST_FILE="YES",
        ENABLE_APP_SANDBOX="NO",
        LD_RUNPATH_SEARCH_PATHS=[
            "$(inherited)",
            "@executable_path/../Frameworks",
            "@loader_path/../Frameworks",
        ],
        ENABLE_TESTABILITY="YES",
    )
    if name == "CometKVM":
        settings.update(
            INFOPLIST_FILE="Resources/Info.plist",
            MARKETING_VERSION="1.0.0",
            CURRENT_PROJECT_VERSION="1",
        )
        settings.update(
            INFOPLIST_KEY_CFBundleDisplayName="Comet KVM",
            INFOPLIST_KEY_NSMicrophoneUsageDescription="Forward your microphone to the computer connected to Comet when you enable microphone forwarding.",
            INFOPLIST_KEY_LSApplicationCategoryType="public.app-category.utilities",
            INFOPLIST_KEY_NSPrincipalClass="NSApplication",
            INFOPLIST_KEY_NSHighResolutionCapable="YES",
            INFOPLIST_KEY_NSLocalNetworkUsageDescription="Connect to your Comet KVM appliances on the local network.",
        )
    target_dependencies = []
    if name == "CometUITests":
        settings["TEST_TARGET_NAME"] = "CometKVM"
        proxy = obj(
            "UIProxy",
            "PBXContainerItemProxy",
            containerPortal=oid("Project"),
            proxyType=1,
            remoteGlobalIDString=oid("CometKVMTarget"),
            remoteInfo="CometKVM",
        )
        target_dependencies.append(
            obj(
                "UIDependency",
                "PBXTargetDependency",
                target=oid("CometKVMTarget"),
                targetProxy=proxy,
            )
        )
    targets.append(
        obj(
            name + "Target",
            "PBXNativeTarget",
            buildConfigurationList=config_list(name, settings),
            buildPhases=phases,
            buildRules=[],
            dependencies=target_dependencies,
            name=name,
            packageProductDependencies=package_dependencies,
            productName=name,
            productReference=product,
            productType=kind,
        )
    )

# Add standard build and test schemes so a fresh checkout can run xcodebuild immediately.
product_group = obj(
    "Products", "PBXGroup", children=products, name="Products", sourceTree="<group>"
)
main_group = obj(
    "MainGroup", "PBXGroup", children=groups + [product_group], sourceTree="<group>"
)
project = obj(
    "Project",
    "PBXProject",
    attributes={"LastUpgradeCheck": "2660", "BuildIndependentTargetsInParallel": "YES"},
    buildConfigurationList=config_list(
        "Project",
        {
            "SDKROOT": "macosx",
            "CLANG_ENABLE_MODULES": "YES",
            "SWIFT_VERSION": "5.0",
            "MACOSX_DEPLOYMENT_TARGET": "14.0",
        },
    ),
    compatibilityVersion="Xcode 15.0",
    developmentRegion="en",
    hasScannedForEncodings=0,
    knownRegions=["en", "Base"],
    mainGroup=main_group,
    packageReferences=[package],
    productRefGroup=product_group,
    projectDirPath="",
    projectRoot="",
    targets=targets,
)


# Serialize the OpenStep property-list structure without requiring a project generator dependency.
def encode(value, level=0):
    if isinstance(value, dict):
        return (
            "{\n"
            + "".join(
                "\t" * (level + 1)
                + json.dumps(k)
                + " = "
                + encode(v, level + 1)
                + ";\n"
                for k, v in value.items()
            )
            + "\t" * level
            + "}"
        )
    if isinstance(value, list):
        return "(" + ", ".join(encode(v, level) for v in value) + ")"
    return str(value) if isinstance(value, int) else json.dumps(value)


folder = root / "CometKVM.xcodeproj"
folder.mkdir(exist_ok=True)
(folder / "project.pbxproj").write_text(
    "// !$*UTF8*$!\n"
    + encode(
        dict(
            archiveVersion=1,
            classes={},
            objectVersion=60,
            objects=objects,
            rootObject=project,
        )
    )
    + "\n"
)
schemes = folder / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)


# Point shared schemes at the generated native targets using the same deterministic identifiers.
def reference(name):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{oid(name+"Target")}" BuildableName="{name}.{"app" if name == "CometKVM" else "xctest"}" BlueprintName="{name}" ReferencedContainer="container:CometKVM.xcodeproj"/>'


(schemes / "CometKVM.xcscheme").write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2660" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference('CometKVM')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{reference('CometCoreTests')}</TestableReference><TestableReference skipped="NO">{reference('CometUITests')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference('CometKVM')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference('CometKVM')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>""")
print("Generated CometKVM.xcodeproj")
