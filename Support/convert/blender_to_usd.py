# Blender 無頭轉檔：GLB/glTF/FBX/blend → USDC（SceneKit 看得懂）。.blend 關掉自動執行腳本
import bpy, os
SRC, OUT = os.environ["O42_IN"], os.environ["O42_OUT"]
try:
    ext = SRC.rsplit(".", 1)[-1].lower()
    if ext == "blend":
        bpy.ops.wm.open_mainfile(filepath=SRC, use_scripts=False)
    else:
        bpy.ops.wm.read_factory_settings(use_empty=True)
        if ext in ("glb", "gltf"): bpy.ops.import_scene.gltf(filepath=SRC)
        elif ext == "fbx": bpy.ops.import_scene.fbx(filepath=SRC)
        else: raise RuntimeError("不支援 ." + ext)
    bpy.ops.wm.usd_export(filepath=OUT, export_materials=True, export_animation=False,
                          convert_orientation=True, export_global_forward_selection="NEGATIVE_Z", export_global_up_selection="Y")
except BaseException as e:
    with open(OUT + ".err", "w") as fh: fh.write(str(e))
