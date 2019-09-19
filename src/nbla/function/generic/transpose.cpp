// Copyright (c) 2017 Sony Corporation. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include <nbla/array.hpp>
#include <nbla/function/transpose.hpp>
#include <nbla/utils/nd_index.hpp>
#include <nbla/variable.hpp>

namespace nbla {

NBLA_REGISTER_FUNCTION_SOURCE(Transpose, const vector<int> &);

template <typename T>
void Transpose<T>::setup_impl(const Variables &inputs,
                              const Variables &outputs) {
  const int ndim = inputs[0]->ndim();
  NBLA_CHECK(ndim == axes_.size(), error_code::value,
             "Length of axes must be same as inputs. Given %d != %d.", ndim,
             axes_.size());

  Shape_t shape(ndim);
  for (int i = 0; i < ndim; i++) {
    NBLA_CHECK(axes_[i] < inputs[0]->shape().size(), error_code::value,
               "axes must be less than ndim of inputs[0]. "
               "axes[%d]: %d >= ndim of inputs[0]: %d.",
               i, axes_[i], inputs[0]->shape().size());
    for (int i2 = 0; i2 < i; i2++) {
      NBLA_CHECK(axes_[i] != axes_[i2], error_code::value,
                 "Axes duplicated. axes[%d]: %d == axes[%d]: %d.", i, axes_[i],
                 i2, axes_[i2]);
    }
    shape[i] = inputs[0]->shape()[axes_[i]];
  }
  outputs[0]->reshape(shape, true);

  v_axes_.reshape(Shape_t{ndim}, true);
  v_x_strides_.reshape(Shape_t{ndim}, true);
  v_y_strides_.reshape(Shape_t{ndim}, true);
  v_y_shape_.reshape(Shape_t{ndim}, true);
  Context cpu; // CPU Context
  int64_t *p_axes = v_axes_.cast_data_and_get_pointer<int64_t>(cpu, true);
  int64_t *p_x_strides =
      v_x_strides_.cast_data_and_get_pointer<int64_t>(cpu, true);
  int64_t *p_y_strides =
      v_y_strides_.cast_data_and_get_pointer<int64_t>(cpu, true);
  int64_t *p_y_shape = v_y_shape_.cast_data_and_get_pointer<int64_t>(cpu, true);
  for (int i = 0; i < ndim; ++i) {
    p_axes[i] = axes_[i];
    p_x_strides[i] = inputs[0]->strides()[i];
    p_y_strides[i] = outputs[0]->strides()[i];
    p_y_shape[i] = outputs[0]->shape()[i];
  }
}

template <class T>
void Transpose<T>::forward_impl(const Variables &inputs,
                                const Variables &outputs) {
  auto ndim = inputs[0]->ndim();
  auto x_data = inputs[0]->get_data_pointer<T>(this->ctx_);
  auto y_data = outputs[0]->cast_data_and_get_pointer<T>(this->ctx_, true);
  auto y_index = ndi::make_index(ndim, Size_t(0));
  auto y_shape = outputs[0]->shape();

  auto y2x_strides = std::vector<Size_t>(ndim);
  for (int i = 0; i < ndim; i++) {
    y2x_strides.at(i) = inputs[0]->strides().at(axes_.at(i));
  }

  int i = 0;
  do {
    y_data[i++] = x_data[ndi::nd2flat(y_index, y2x_strides)];
  } while (ndi::increment(y_index, y_shape));
}

template <class T>
void Transpose<T>::backward_impl(const Variables &inputs,
                                 const Variables &outputs,
                                 const vector<bool> &propagate_down,
                                 const vector<bool> &accum) {
  if (!propagate_down[0])
    return;

  auto ndim = inputs[0]->ndim();
  auto x_grad = inputs[0]->cast_grad_and_get_pointer<T>(this->ctx_, !accum[0]);
  auto y_grad = outputs[0]->get_grad_pointer<T>(this->ctx_);
  auto x_index = ndi::make_index(ndim, Size_t(0));
  auto x_shape = inputs[0]->shape();

  auto x2y_strides = std::vector<Size_t>(ndim);
  for (int i = 0; i < ndim; i++) {
    x2y_strides.at(axes_.at(i)) = outputs[0]->strides().at(i);
  }

  int i = 0;
  if (accum[0]) {
    do {
      x_grad[i++] += y_grad[ndi::nd2flat(x_index, x2y_strides)];
    } while (ndi::increment(x_index, x_shape));
  } else {
    do {
      x_grad[i++] = y_grad[ndi::nd2flat(x_index, x2y_strides)];
    } while (ndi::increment(x_index, x_shape));
  }
}
}
