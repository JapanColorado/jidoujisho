cmake_minimum_required(VERSION 3.4.1)  # for example

# mecab's bundled C++ uses pre-C++17 features (the `register` storage-class
# specifier and `std::binary_function`). Pin the standard to C++14 so the
# legacy sources keep compiling under NDK 27's Clang.
set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
add_compile_options(-Wno-register -Wno-error=register)

add_library( mecab_dart

             # Sets the library as a shared library.
             SHARED

             # Provides a relative path to your source file(s).
             ../ios/Classes/char_property.cpp
             ../ios/Classes/eval.cpp
             ../ios/Classes/nbest_generator.cpp
             ../ios/Classes/tokenizer.cpp
             ../ios/Classes/connector.cpp
             ../ios/Classes/iconv_utils.cpp
             ../ios/Classes/param.cpp
             ../ios/Classes/utils.cpp
             ../ios/Classes/context_id.cpp
             ../ios/Classes/libmecab.cpp
             ../ios/Classes/string_buffer.cpp
             ../ios/Classes/viterbi.cpp
             ../ios/Classes/dictionary.cpp
             ../ios/Classes/dart_ffi.cpp
             ../ios/Classes/tagger.cpp
             ../ios/Classes/writer.cpp
             )
