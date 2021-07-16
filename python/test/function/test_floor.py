# Copyright 2018,2019,2020,2021 Sony Corporation.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import pytest
import numpy as np
import nnabla.functions as F
from nbla_test_utils import list_context

ctxs = list_context('Floor')


def ref_floor(x):
    return np.floor(x)


def ref_grad_floor(x, dy, **kw):
    return dy.flatten()


@pytest.mark.parametrize("ctx, func_name", ctxs)
@pytest.mark.parametrize("seed", [313])
def test_floor_forward_backward(seed,
                                ctx, func_name):
    from nbla_test_utils import cap_ignore_region, \
        function_tester
    rng = np.random.RandomState(seed)
    inputs = [rng.randn(2, 3, 4).astype(np.float32) * 2]

    function_tester(rng, F.floor,
                    ref_floor,
                    inputs,
                    atol_b=1e-3, backward=[True],
                    ctx=ctx, func_name=func_name,
                    ref_grad=ref_grad_floor)


@pytest.mark.parametrize("ctx, func_name", ctxs)
@pytest.mark.parametrize("seed", [313])
def test_floor_double_backward(seed,
                               ctx, func_name):
    from nbla_test_utils import cap_ignore_region, backward_function_tester
    rng = np.random.RandomState(seed)
    inputs = [rng.randn(2, 3, 4).astype(np.float32) * 2]

    backward_function_tester(rng, F.floor,
                             inputs,
                             atol_accum=1e-2,
                             backward=[True],
                             ctx=ctx)
