1.#编译810_driver_test/projects 下所有工程
工具：linkedsemi_tools/build_all_apps.sh  
# 只列出会编译哪些工程，不编译
./linkedsemi_tools/build_all_apps.sh --list
# 只编译某个测试组eg
./linkedsemi_tools/build_all_apps.sh -a 810_driver_test/projects/spi_test
# 换板子 / 换构建目录 / 单工程超时 10 分钟
./linkedsemi_tools/build_all_apps.sh -b 'lsqsh_evb@2os/lsqsh/cpu1' -d build -t 600
# 遇到第一个失败就停
./linkedsemi_tools/build_all_apps.sh --stop-on-error