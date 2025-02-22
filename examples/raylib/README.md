For the desktop version, run the command:
```
zig build --release=fast run
```

To run the example in a web browser, first install emsdk. Once emsdk is installed, set it up by running
```
emsdk install latest
```

Find the folder where it's installed and run
```
zig build --release=fast -Dtarget=wasm32-emscripten --sysroot [path to emsdk]/upstream/emscripten run
```
