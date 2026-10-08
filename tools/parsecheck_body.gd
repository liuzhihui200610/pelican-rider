extends SceneTree
## parsecheck.sh 的第 1 步载荷：只加载 main.gd，秒级暴露「缩进 / := 声明」类错误。
## 单独放这里是为了不往项目根目录写临时文件（根目录保持 0 散落）。
func _init():
	var s = load("res://scripts/main.gd")
	print("PARSE_RESULT=", "OK" if s != null else "FAIL")
	quit()
