For the desktop version, run the command:
```
zig build run_fm
```

To run the example in a web browser, first install emsdk. Once emsdk is installed, set it up by running
```
emsdk install latest
```

Find the folder where it's installed and run
```
zig build -Dtarget=wasm32-emscripten --sysroot [path to emsdk]/upstream/emscripten run_fm
```
