"""Loading the model correctly across transformers versions.

The checkpoint was trained with `scale_attn_by_inverse_layer_idx=True`. In transformers 4.x
the default (SDPA) attention path silently ignores that setting, which leaves the weights
intact but makes the model compute the wrong thing: validation loss 4.4 instead of 0.9 on
the same data. The "eager" attention path honours it. transformers 5 is correct either way.
"""

import transformers
from transformers import AutoModelForCausalLM

BASE_MODEL = "stanford-crfm/music-small-800k"


def load_model(source=BASE_MODEL, dropout=None):
    """`dropout` overrides the model's embedding, residual and attention dropout (0.1 in the
    pretrained config); only matters while training."""
    kwargs = {}
    if dropout is not None:
        kwargs.update(resid_pdrop=dropout, embd_pdrop=dropout, attn_pdrop=dropout)
    if int(transformers.__version__.split(".")[0]) < 5:
        kwargs["attn_implementation"] = "eager"
    return AutoModelForCausalLM.from_pretrained(source, **kwargs)
