"""Keep only the 12 Hz decoder used by the built-in CustomVoice speakers."""
import sys

import gguf
import numpy as np


def packaged_weights(tensor):
    data = tensor.data
    if data.nbytes < 100_000 or data.dtype not in (np.float16, np.float32):
        return data
    # Keep the native GGUF tensor types. Rounding mantissas makes these
    # convolution and codebook weights compressible in the installation ZIP.
    bits = np.uint16 if data.dtype == np.float16 else np.uint32
    shift = np.finfo(data.dtype).nmant - 4
    words = data.view(bits)
    rounding_bias = (1 << (shift - 1)) - 1 + ((words >> shift) & 1)
    rounded = ((words + rounding_bias) >> shift) << shift
    return rounded.view(data.dtype)


def write_decoder(source, destination):
    reader = gguf.GGUFReader(source)
    architecture = reader.fields["general.architecture"].contents()
    if architecture != "qwen3tts_tokenizer":
        raise ValueError(f"Unexpected codec architecture: {architecture}")
    writer = gguf.GGUFWriter(destination, architecture)
    for name, field in reader.fields.items():
        if name.startswith("GGUF.") or name == "general.architecture":
            continue
        value_type = field.types[0]
        subtype = field.types[-1] if value_type == gguf.GGUFValueType.ARRAY else None
        writer.add_key_value(name, field.contents(), value_type, sub_type=subtype)
    for tensor in reader.tensors:
        if not tensor.name.startswith("codec.enc."):
            writer.add_tensor(tensor.name, packaged_weights(tensor), raw_dtype=tensor.tensor_type)
    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()


if __name__ == "__main__":
    write_decoder(*sys.argv[1:])
