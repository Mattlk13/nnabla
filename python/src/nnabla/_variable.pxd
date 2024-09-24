# Copyright 2017,2018,2019,2020,2021 Sony Corporation.
# Copyright 2021 Sony Group Corporation.
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

from libcpp.vector cimport vector
from libcpp.string cimport string
from libcpp.unordered_set cimport unordered_set
from libcpp.functional cimport function as std_function
from libcpp cimport bool as cpp_bool
from libc.stdint cimport int64_t
from libcpp.memory cimport shared_ptr
from _common import *
from _array cimport *
from _context cimport *
from _nd_array cimport *


cdef extern from "nbla/variable.hpp" namespace "nbla":
    cdef cppclass CVariable "nbla::Variable":
        CVariable(Shape_t) except +
        CVariable(NdArrayPtr) except +
        Shape_t shape()
        Size_t size(Size_t) except +
        Size_t ndim()
        void reshape(Shape_t, cpp_bool) except +
        shared_ptr[CVariable] view() except +
        shared_ptr[CVariable] view(const Shape_t & ) except +
        NdArrayPtr data() except +
        NdArrayPtr grad() except +
        void set_data(NdArrayPtr) except +
        void set_grad(NdArrayPtr) except +
    ctypedef shared_ptr[CVariable] VariablePtr

cdef extern from "nbla/computation_graph/variable.hpp" namespace "nbla":
    cdef cppclass CgFunction
    ctypedef shared_ptr[CgFunction] CgFunctionPtr
    cdef cppclass CCommunicatorBackwardCallback "nbla::CommunicatorBackwardCallback":
        CCommunicatorBackwardCallback() except +
    ctypedef shared_ptr[CCommunicatorBackwardCallback] CommunicatorBackwardCallbackPtr
    ctypedef std_function[void(const CgFunctionPtr &) noexcept] function_hook_type

    cdef cppclass FunctionHookWithObject:
        ctypedef std_function[void(void *) noexcept] setup_callback_type
        ctypedef std_function[void(void *) noexcept] cleanup_callback_type
        ctypedef std_function[void(void *, const CgFunctionPtr &) noexcept] callback_type
        FunctionHookWithObject()
        FunctionHookWithObject(void *obj, callback_type cb,
                               setup_callback_type setup_cb,
                               cleanup_callback_type clean_cb)

    cdef cppclass CgVariable:
        CgVariable() except +
        CgVariable(cpp_bool need_grad) except +
        CgVariable(Shape_t shape) except +
        CgVariable(Shape_t shape, cpp_bool need_grad) except +
        CgVariable(VariablePtr)
        CgVariable(VariablePtr, cpp_bool need_grad)
        cpp_bool need_grad() const
        cpp_bool need_grad_is_set() const
        void set_need_grad(cpp_bool b)
        void unset_need_grad()
        cpp_bool need_grad_state() const
        cpp_bool need_grad_state_is_set() const
        void set_need_grad_state(cpp_bool b)
        void unset_need_grad_state()
        cpp_bool recompute() const
        void set_recompute(cpp_bool b)
        void set_parent(CgFunctionPtr func) except +
        CgFunctionPtr parent()
        VariablePtr variable()
        int rank() const
        void set_rank(int rank) except +
        void forward(cpp_bool clear_buffer, cpp_bool clear_no_need_grad, unordered_set[CgFunctionPtr] *fclosed, function_hook_type function_pre_hook, function_hook_type function_post_hook) except + nogil
        void backward(NdArrayPtr grad, cpp_bool clear_buffer, vector[CommunicatorBackwardCallbackPtr] communicator_callbacks, function_hook_type function_pre_hook, function_hook_type function_post_hook, cpp_bool clear_initial_grad) except + nogil
        void set_persistent(cpp_bool b)
        cpp_bool persistent()
        void clear_during_auto_forward() except +
        string name() except +
        void set_name(string name) except +
        vector[CgFunctionPtr] function_references() except +
        void remove_function_reference(CgFunction * func) except +
        void update_python_user_reference_counts(const int diff) except +
    ctypedef shared_ptr[CgVariable] CgVariablePtr

cdef extern from "nbla/computation_graph/function.hpp" namespace "nbla":
    cdef cppclass CFunction
    ctypedef shared_ptr[CFunction] FunctionPtr
    cdef cppclass CgFunction:
        CgFunction(FunctionPtr func) except +
        FunctionPtr function() const
        cpp_bool need_grad() const
        int rank() const
        void set_outputs(const vector[CgVariablePtr] & outputs) except +
        const vector[CgVariablePtr] inputs()
        vector[CVariable *] function_inputs() except +
        vector[VariablePtr] function_outputs_shared() except +
        string info() const
        void set_info(const string & info)

cdef class Context:
    cdef vector[string] backend_
    cdef public str array_class
    cdef public str device_id


cdef class CommunicatorBackwardCallback:
    cdef CommunicatorBackwardCallbackPtr var

    @staticmethod
    cdef create_from_ccallback(CommunicatorBackwardCallbackPtr varsp)

cdef class Variable:
    cdef CgVariablePtr _var # DO NOT ACCESS IT DIRECTLY! Use setter and getter.
    cdef CgVariable * _varp # DO NOT ACCESS IT DIRECTLY! Use setter and getter.
    cdef public object info
    """
    Information of the variable.
    """

    # Setter and getter of _var and _varp
    cdef void set_var(self, CgVariablePtr var) noexcept
    cdef inline CgVariablePtr get_var(self) noexcept
    cdef inline CgVariable * get_varp(self) noexcept
    cdef inline CgVariable * get_varp_no_gil(self) noexcept nogil # for no-gil functions

    @staticmethod
    cdef create_from_cvariable(shared_ptr[CVariable] varsp)

    @staticmethod
    cdef create_from_cg_variable(CgVariablePtr cgv)

cdef FunctionHookWithObject create_function_hook_with_object(object callback) noexcept
