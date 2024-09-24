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

from __future__ import print_function

from libcpp.vector cimport vector
from libcpp.string cimport string
from libc.stdint cimport int64_t, intptr_t
from libcpp.memory cimport make_shared, shared_ptr, const_pointer_cast
from cpython cimport PyObject, Py_INCREF, Py_DECREF
cimport _variable
from _variable cimport CVariable, CContext, Shape_t, dtypes
from _nd_array cimport CNdArray, CSyncedArray
cimport function
from function cimport CgFunction

# Numpy
import numpy as np
cimport numpy as np
np.import_array()

cimport _arithmetic_ops as AOP
from _computation_graph cimport steal_variable_from_to
cimport _indexing as IDX


ctypedef void * voidp


cdef class Context:

    """
    Context is used to specify the computation engine (cpu, cuda, cudnn etc.) which the
    function operator modules and optimizer modules shall be ran on.
    The context can be set for each function, as well as set globally with functions
    listed in the :meth:`context-specifier`.

    Args:
        backend (list of str): 'cpu', 'cuda', 'cudnn' etc.
        array_class (str): str, 'CpuArray', 'CpuCachedArray', 'CudaArray', 'CudaCachedArray' etc.
        device_id (str): str, default '0'

    """

    def __init__(self, backend=None, array_class='',
                 device_id='0'):
        if backend is None:
            backend = ['cpu:float']
        for b in backend:
            self.backend_.push_back(b)
        self.array_class = array_class
        self.device_id = device_id

    @property
    def backend(self):
        ret = []
        for b in self.backend_:
            ret.append(b)
        return ret

    @backend.setter
    def backend(self, backends):
        self.backend_.resize(len(backends))
        for i, b in enumerate(backends):
            self.backend_[i] = b

    def __getitem__(self, key):
        return getattr(self, key)

    def __repr__(self):
        return "Context(backend={}, array_class='{}'"\
            ", device_id='{}')".format(
                self.backend, self.array_class,
                self.device_id)

    def __str__(self):
        return repr(self)


cdef class CommunicatorBackwardCallback:
    @staticmethod
    cdef create_from_ccallback(shared_ptr[CCommunicatorBackwardCallback] varsp):
        var = CommunicatorBackwardCallback()
        var.var = varsp

        return var

cdef void callback_incref(void *obj) noexcept with gil:
    Py_INCREF(<object>obj)

cdef void callback_decref(void *obj) noexcept with gil:
    Py_DECREF(<object>obj)

cdef void callback_call_callable(void *obj, const CgFunctionPtr &f) except + with gil:
    cdef object cbl = <object>obj
    cbl(function.Function.create_from_c(const_pointer_cast[CgFunction, CgFunction](<const shared_ptr[CgFunction]&>f)))

cdef FunctionHookWithObject create_function_hook_with_object(object callback) noexcept:
    return FunctionHookWithObject(<void*>callback,
                                  <std_function[void(void*, const CgFunctionPtr&) noexcept]>callback_call_callable,
                                  <std_function[void(void*) noexcept]>callback_incref,
                                  <std_function[void(void*) noexcept]>callback_decref)



cdef class Variable:
    """
    :class:`nnabla.Variable` is used to construct computation graphs (neural networks) together
    with functions in :ref:`functions`
    and :ref:`parametric-functions` .
    It also provides a method to execute forward and backward
    propagation of the network.
    The :class:`nnabla.Variable` class holds:

    * Reference to the parent function in a
      computation graph. This provides traceability of all connections in the computation graph.
    * Both data and error
      signal (gradient) containers as :class:`nnabla.NdArray` s.
    * Some additional information of the computation graph.

    :class:`~nnabla.Variable` overrides some arithmetic operators
    (``+``, ``-``, ``*``, ``/``, ``**``). Operands can be either a scalar number,
    :class:`~nnabla.NdArray` or :class:`~nnabla.Variable`.
    If :class:`~nnabla.NdArray` is given as either of left or right operand,
    the arithmetic operation returns an :class:`~nnabla.NdArray` which stores the
    output of the computation immediately invoked. Otherwise, it returns
    :class:`~nnabla.Variable` holds the graph connection. The computation
    is invoked immediately when `nnabla.auto_forward`
    or `nnabla.set_auto_forward(True)` is used.

    Note:
        Relational operators  :code:`==` and :code:`!=` of two  :obj:`Variable` s are
        defined as an address comparison of underlying C++ instances
        (:code:`nbla::Variable`). Also, :func:`hash` function, which is often used
        in a key for :obj:`set` and :obj:`dict`, is based on the address.

    See also:
        `Python API Tutorial
        <http://nnabla.readthedocs.io/en/latest/python/tutorial/python_api.html>`_.

    Args:
        shape (Iterable of int): Shape of variable.
        need_grad (bool): Flag for backprop or not.

    """
    EXCEPTIONS_AT_DEALLOC = []

    @staticmethod
    def _check_exception_at_dealloc():
        exceptions = Variable.EXCEPTIONS_AT_DEALLOC
        if not exceptions:
            return
        err = exceptions.pop(0)
        raise err

    cdef void set_var(self, CgVariablePtr var) noexcept:
        # New CgVariable traces this Variable.
        var.get().update_python_user_reference_counts(1)

        if self._var:
            # Old CgVariable purges this Variable.
            self.get_varp().update_python_user_reference_counts(-1)

        self._var = var
        self._varp = var.get()

    cdef inline CgVariablePtr get_var(self) noexcept:
        return self._var

    cdef inline CgVariable * get_varp(self) noexcept:
        return self._varp

    cdef inline CgVariable * get_varp_no_gil(self) noexcept nogil:
        return self._varp

    def __cinit__(self, Shape_t shape=[], need_grad=None, info=None):
        self.info = info
        if need_grad is None:
            self.set_var(make_shared[CgVariable](shape))
        else:
            self.set_var(make_shared[CgVariable](shape, < bint?> need_grad))

    @staticmethod
    cdef create_from_cvariable(shared_ptr[CVariable] varsp):
        cdef shared_ptr[CgVariable] v_sp = make_shared[CgVariable](varsp)
        var = Variable()
        var.set_var(v_sp)
        return var

    @staticmethod
    cdef create_from_cg_variable(CgVariablePtr cgv):
        var = Variable()
        var.set_var(cgv)
        return var

    @staticmethod
    def from_numpy_array(data, grad=None, need_grad=None):
        """Create a Variable object from Numpy array(s).

        The ``data`` is initialized with the given Numpy array, as well as
        ``grad`` if given.

        The shape is also determined by the given array.

        Args:
            data (~numpy.ndarray): Values copied to the ``data`` of the created
                Variable.
            grad (~numpy.ndarray): Values copied to the ``grad`` of the created
                Variable.
            need_grad (bool): Flag for backprop or not.

        Returns: 
            Variable

        """
        data = np.asarray(data)
        var = Variable(data.shape, need_grad)
        var.data.cast(data.dtype)
        var.d = data
        if grad is None:
            return var
        grad = np.asarray(grad)
        assert data.shape == grad.shape
        var.grad.cast(grad.dtype)
        var.g = grad
        return var

    def __dealloc__(self):
        # Clear data when an user releases all the references of this Variable.
        # This feature is required to release the memory during forward
        # execution in auto-forward mode.
        # TODO: Implement this feature as the core design of NNabla and remove
        #       this workaround.
        # Dev Note: You must avoid invoking Python operations in Cython 
        #           __dealloc__. When Cython __dealloc__() method is called,
        #           Python objects are partially destroyed. In particular,
        #           at the end of Python process, the invocations of
        #           __dealloc__() of all Variables during Python object
        #           destruction could return many errors.
        try:
            self.get_varp().clear_during_auto_forward()
        except RuntimeError as err:
            import sys
            print("Ignoring an exception in __dealloc__.", err)
            print("Please run nnabla.Variable._check_exception_at_dealloc() to handle the exception.")
            Variable.EXCEPTIONS_AT_DEALLOC.append(err)
        finally:
            # Delete references
            self.get_varp().update_python_user_reference_counts(-1)

    @property
    def get_number_of_references(self):
        """
        Gets the number of referneces to the same memory objects.


        Returns: 
            `int`

        """
        # This is mainly used for pytest.
        cdef CgVariable* cgv = self.get_varp()
        cdef CVariable* v = cgv.variable().get()
        cdef CNdArray* ndarr = v.data().get()
        cdef CSyncedArray* syncarr = ndarr.array().get()
        return syncarr.get_python_user_reference_counts()

    def __repr__(self):
        return "<Variable({}, need_grad={}) at {}>".format(
            self.shape, self.need_grad, hex(id(self)))

    def __eq__(self, other):
        '''Equal operator compares the addresses of underlying C++ objects
        (``nbla::Variable``).
        '''
        cdef CVariable* v = (< Variable > self).get_varp().variable().get()
        cdef CVariable* w = (< Variable ?> other).get_varp().variable().get()
        return v == w

    def __hash__(self):
        '''Returns hash of the integer address of holding C++ object.
        '''
        cdef CVariable* v = ( < Variable > self).get_varp().variable().get()
        return hash(< intptr_t > (v))

    def apply(self, **kwargs):
        '''Helper for setting property, then return self.
        '''
        for k, v in kwargs.items():
            setattr(self, k, v)
        return self

    @property
    def shape(self):
        """
        Gets the shape of the variable.


        Returns: 
            tuple of :obj:`int`

        """
        return tuple(self.get_varp().variable().get().shape())

    @property
    def size(self):
        """
        Gets the size of the variable.

        Returns: 
            :obj:`int`

        """
        return self.get_varp().variable().get().size(-1)

    @property
    def ndim(self):
        """
        Gets the number of dimensions of this variable.

        Returns: 
            int

        """
        return self.get_varp().variable().get().ndim()

    def size_from_axis(self, axis=-1):
        """
        Gets the size followed by the provided axis.

        Example:

            .. code-block:: python

                a = nnabla.Variable([10,9])
                a.size_from_axis()
                # ==> 90
                a.size_from_axis(0)
                # ==> 90
                a.size_from_axis(1)
                # ==> 9
                a.size_from_axis(2)
                # ==> 1

        Args:
            axis (:obj:`int`, optional): -1 as default

        Returns:
            :obj:`int`        
        """
        return self.get_varp().variable().get().size(axis)

    def reset_shape(self, shape, force=False):
        """Resizes the shape of the variable to a specified shape.

        Args:
            shape (Iterable of int): Target shape.
            force (bool): Flag to force reshape.

        Note:
            This method destructively changes the shape of the target variable. For safety, :func:`~nnabla.functions.reshape` should be used instead.

        Returns:
            None

        """
        self.get_varp().variable().get().reshape(shape, force)

    def reshape(self, shape, unlink=False):
        """Returns a new variable, where this variable is reshaped to a specified shape.

        Args:
          shape (Iterable of int): Target shape.
          unlink (bool): Unlink graph connection. Or, keep graph connection, i.e.
            the gradient will be backprop-ed to the original variable.

        Returns:
            :class:`~nnabla.Variable`

        """
        if unlink:
            var = Variable.create_from_cvariable(
                self.get_varp().variable().get().view(shape))
            (< Variable > var).get_varp().set_need_grad(self.get_varp().need_grad_state())
            return var
        from nnabla.functions import reshape
        return reshape(self, shape)

    @property
    def need_grad(self):
        """
        Gets or sets a boolean indicating whether backpropagation is performed at this variable. 

        Args:
            b (bool): Whether backpropagation is performed at this variable.

        Returns:
           bool: Whether this variable requires gradient or not.
        """
        return self.get_varp().need_grad_state()

    @need_grad.setter
    def need_grad(self, b):
        self.get_varp().set_need_grad(b)

    @property
    def recompute(self):
        """
        Gets or sets a boolean indicating whether its data is cleared during forward propagation and recomputation is performed during backward propagation. 

        Args:
            b (bool): Whether recomputation is performed during backward propagation.

        Returns:
           bool: Whether this variable is recomputed during backward propagation.
        """
        return self.get_varp().recompute()

    @recompute.setter
    def recompute(self, b):
        self.get_varp().set_recompute(b)

    def rewire_on(self, var):
        '''Rewire a successor graph of this variable on top of ``var``.

        Args:
            var (:obj:`nnabla.Variable`):
                The array elements and the parent function of ``var`` is
                copied to ``self`` as references.
                Note that the parent function of ``var`` is removed.

        Example:

            .. code-block:: python

                # A. Create a graph A.
                xa = nn.Variable((2, 8), need_grad=True)
                ya = F.tanh(PF.affine(xa, 10, name='a'))

                # B. Create a graph B.
                xb = nn.Variable((2, 16), need_grad=True)
                yb = F.tanh(PF.affine(
                    F.tanh(PF.affine(xb, 8, name='b1')),
                    8, name='b2'))

                # C. Rewire the graph A on top of B such that
                #    `xb->B->(yb->)xa->A->ya`. Note `yb` is gone.
                xa.rewire_on(yb)

                # D. Execute the rewired graph.
                xb.d = 1
                ya.forward()
                ya.backward()

        '''
        steal_variable_from_to(( < Variable?> var).get_var(), self.get_var())

    @property
    def data(self):
        """Returns the data held by this variable, as a
        :class:`~nnabla.NdArray`. This can also be used as a setter.

        Args:
            ndarray (~nnabla.NdArray): NdArray object. Size must
                be the same as this Variable.

        Returns:
            :class:`~nnabla.NdArray`
        """
        return NdArray.create(self.get_varp().variable().get().data())

    @data.setter
    def data(self, NdArray ndarray):
        self.get_varp().variable().get().set_data(ndarray.arr)

    @property
    def grad(self):
        """Returns the gradient held by this variable, as a
        :class:`~nnabla.NdArray`. This can also be used as a setter.

        Args:
            ndarray (~nnabla.NdArray): NdArray object. Size must
                be the same as this Variable.

        Returns:
            :class:`~nnabla.NdArray`
        """
        return NdArray.create(self.get_varp().variable().get().grad())

    @grad.setter
    def grad(self, NdArray ndarray):
        self.get_varp().variable().get().set_grad(ndarray.arr)

    @property
    def d(self):
        """
        Returns the values held by this variable, as a :class:`numpy.ndarray`.
        Note that the values are referenced (not copied). Therefore, the
        modification of the returned ndarray will affect the data of the
        NNabla array.
        This method can be called as a setter to set the value held by this variable.
        Refer to the documentation of the setter `nnabla.NdArray.data`
        for detailed behaviors of the setter.

        Args:
            value(:obj:`numpy.ndarray`) (optional)

        Returns:
            :obj:`numpy.ndarray`
        """
        return self.data.data

    @d.setter
    def d(self, value):
        self.data.data = value

    @property
    def g(self):
        """
        Returns the gradient values held by this variable, as a :class:`numpy.ndarray`.
        Note that the values are referenced (not copied). Therefore, the
        modification of the returned ndarray will affect the data of the
        NNabla array.
        This method can be called as a setter to set the gradient held by this variable.        
        Refer to the documentation of the setter `nnabla.NdArray.data`
        for detailed behaviors of the setter.

        Args:
            value(:obj:`numpy.ndarray`)

        Returns:
            :obj:`numpy.ndarray`
        """
        return self.grad.data

    @g.setter
    def g(self, value):
        self.grad.data = value

    def bool_fill_(self, mask, value):
        """
        Return a new but inplaced :obj:`nnabla.Variable` filled with value where mask is non-zero.

        Args:
            mask (:obj:`nnabla.NdArray`): Mask with which to fill. Non-zero/zero elements are supposed to be a binary mask as 1/0. No gradients are computed with respect to mask.
            value (float): The value to fill.

        Returns:
            :obj:`nnabla.Variable`

        """
        import nnabla.functions as F
        return F.bool_fill(self, mask, value, outputs=[self.data])

    masked_fill_ = bool_fill_

    @property
    def parent(self):
        """
        Returns the parent function of this variable.
        This method can also be called as a setter.

        Args:
            func(:obj:`nnabla.function.Function`)

        Returns:
            :obj:`nnabla.function.Function`

        """
        cdef CgFunctionPtr cgf = self.get_varp().parent()
        if not cgf:
            return None
        return function.Function.create_from_c(cgf)

    @parent.setter
    def parent(self, func):
        cdef CgFunctionPtr cg_func = (< function.Function ?> func).fun
        assert cg_func, "TODO"
        self.get_varp().set_parent(cg_func)

    @property
    def function_references(self):
        """
        Returns a list of functions which take this variable as an input.
        This method can be called only as a getter.

        Returns:
            list of `nnabla.function.Function`

        """
        cdef vector[CgFunctionPtr] fs = self.get_varp().function_references()

        return [function.Function.create_from_c(f) for f in fs]


    def forward(self, cpp_bool clear_buffer=False, cpp_bool clear_no_need_grad=False,
                object function_pre_hook=None, object function_post_hook=None):
        """
        Performs a forward propagation from the root node to this variable.
        The forward propagation is performed on a subset of variables
        determined by the dependency of this variable.
        The subset is recursively constructed by tracking variables that the 
        variables in the subset depend on, starting from this variable,
        until it reaches the root variable(s) in the function graph.
        See also :obj:`~nnnabla.forward_all`, which performs forward computations for all variables within the input graph.

        Args:
            clear_buffer (bool): Clear the no longer referenced variables
                during forward propagation to save memory.
                This is usually set as True in an inference
                or a validation phase. Default is False.
                Note that all unnecessary intermediate variables will be cleared unless set explicitly as `persistent=True`.
            clear_no_need_grad (bool): Clear the unreferenced variables with
                need_grad=False during forward propagation.
                True is usually used when calling this during training.
                This is ignored when clear_buffer=True.
            function_pre_hook(callable):
                This callable object is called immediately before each function is executed.
                It must take :obj:`~nnabla.function.Function` as an input.
                The default is None.
            function_post_hook(callable):
                This callable object is called immediately after each function is executed.
                It must take :obj:`~nnabla.function.Function` as an input.
                The default is None.

        """
        cdef function_hook_type function_pre_hook_c
        cdef function_hook_type function_post_hook_c

        if function_pre_hook is not None:
            function_pre_hook_c = create_function_hook_with_object(function_pre_hook)
        if function_post_hook is not None:
            function_post_hook_c = create_function_hook_with_object(function_post_hook)

        with nogil:
            self.get_varp_no_gil().forward(clear_buffer, clear_no_need_grad, NULL, function_pre_hook_c, function_post_hook_c)


    def backward(self, grad=1, cpp_bool clear_buffer=False, communicator_callbacks=None,
                 function_pre_hook=None, function_post_hook=None):
        """
        Performs a backward propagation starting from this variable until
        the root variable(s) is/are reached in the function graph.
        The propagation will stop at a variable with need_grad=False.

        Args:
            grad(scalar, :obj:`numpy.ndarray`, :obj:`nnabla.NdArray`, or None):
                The gradient signal value(s) of this variable.
                The default value 1 is used in an usual neural network training.
                This option is useful if you have a gradient computation module outside NNabla,
                and want to use that result as a gradient signal.
                Note that this doesn't modifies the grad values of this variable,
                instead assign received values to its gradient temporarily.
                Also, if the :class:`~nnabla.Variable` you want to execute
                `nnabla._variable.Variable.backward` is an unlinked variable from another,
                and the corresponding :class:`~nnabla.Variable` holds the pre-computed gradient values,
                **You need to set grad=None**, otherwise, for that backward pass (propagated from the unlinked :class:`~nnabla.Variable`),
                pre-computed gradient values are **ignored**.
            clear_buffer(bool): Clears the no longer referenced variables
                during backpropagation to save memory. Note that all unnecessary intermediate variables will be cleared unless set explicitly as `persistent=True`.
            communicator_callbacks(:obj:`nnabla.CommunicatorBackwardCallback` or list of :obj:`nnabla.CommunicatorBackwardCallback`):
                The callback functions invoked when 1) backward computation
                of each function is finished and 2) all backward
                computation is finished.
            function_pre_hook(callable):
                This callable object is called immediately before each function is executed.
                It must take :obj:`~nnabla.function.Function` as an input.
                The default is None.
            function_post_hook(callable):
                This callable object is called immediately after each function is executed.
                It must take :obj:`~nnabla.function.Function` as an input.
                The default is None.


        Example:

            We first explain simple backward usage.

            .. code-block:: python

                import nnabla as nn
                import nnabla.functions as F
                import nnabla.parametric_functions as PF
                import numpy as np
                import nnabla.initializer as I

                rng = np.random.seed(217)
                initializer = I.UniformInitializer((-0.1, 0.1), rng=rng)

                x = nn.Variable((8, 3, 32, 32))
                x.d = np.random.random(x.shape)  # random input, just for example.

                y0 = PF.convolution(x, outmaps=64, kernel=(3, 3), pad=(1, 1), stride=(2, 2), w_init=initializer, name="conv1", with_bias=False)
                y1 = F.relu(y0)
                y2 = PF.convolution(y1, outmaps=128, kernel=(3, 3), pad=(1, 1), stride=(2, 2), w_init=initializer, name="conv2", with_bias=False)
                y3 = F.relu(y2)
                y4 = F.average_pooling(y3, kernel=y3.shape[2:])
                y5 = PF.affine(y4, 1, w_init=initializer)
                loss = F.mean(F.abs(y5 - 1.))
                loss.forward()  # Execute forward

                # We can check the current gradient of parameter.
                print(nn.get_parameters()["conv1/conv/W"].g)

            Output :

            .. code-block:: plaintext

                [[[[0. 0. 0.]
                   [0. 0. 0.]
                   [0. 0. 0.]]
                      ...

            Initially all the gradient values should be zero.
            Then let's see what happens after calling backward.

            .. code-block:: python

                loss.backward()
                print(nn.get_parameters()["conv1/conv/W"].g)

            Output :

            .. code-block:: plaintext

                [[[[ 0.00539637  0.00770839  0.0090611 ]
                   [ 0.0078223   0.00978992  0.00720569]
                   [ 0.00879023  0.00578172  0.00790895]]
                                     ...

            Now we know the gradient values are computed and registered by calling `backward`.
            Note that calling `backward` successively **accumulates** the result.
            It means if we execute `backward` again, we get the doubled result.

            .. code-block:: python

                loss.backward()  # execute again.
                print(nn.get_parameters()["conv1/conv/W"].g)

            We can see it's accumulated.

            .. code-block:: plaintext

                [[[[ 0.01079273  0.01541678  0.0181222 ]
                   [ 0.01564459  0.01957984  0.01441139]
                   [ 0.01758046  0.01156345  0.0158179 ]]
                                     ...

            Next is an advanced usage with an unlinked variable (please refer to `get_unlinked_variable`).
            We use the same network, but it is separated by the unlinked variable.

            .. code-block:: python

                import nnabla as nn
                import nnabla.functions as F
                import nnabla.parametric_functions as PF
                import numpy as np
                import nnabla.initializer as I

                rng = np.random.seed(217)  # use the same random seed.
                initializer = I.UniformInitializer((-0.1, 0.1), rng=rng)

                x = nn.Variable((8, 3, 32, 32))
                x.d = np.random.random(x.shape)  # random input, just for example.

                y0 = PF.convolution(x, outmaps=64, kernel=(3, 3), pad=(1, 1), stride=(2, 2), w_init=initializer, name="conv1", with_bias=False)
                y1 = F.relu(y0)
                y2 = PF.convolution(y1, outmaps=128, kernel=(3, 3), pad=(1, 1), stride=(2, 2), w_init=initializer, name="conv2", with_bias=False)
                y3 = F.relu(y2)
                y3_unlinked = y3.get_unlinked_variable()  # the computation graph is cut apart here.
                y4 = F.average_pooling(y3_unlinked, kernel=y3_unlinked.shape[2:])
                y5 = PF.affine(y4, 1, w_init=initializer)
                loss = F.mean(F.abs(y5 - 1.))

                # Execute forward.
                y3.forward()  # you need to execute forward at the unlinked variable first.
                loss.forward()  # Then execute forward at the leaf variable.

                # Execute backward.
                loss.backward()  # works, but backpropagation stops at y3_unlinked.
                print(nn.get_parameters()["conv1/conv/W"].g)  # no gradient registered yet.

            Output :

            .. code-block:: plaintext

                [[[[0. 0. 0.]
                   [0. 0. 0.]
                   [0. 0. 0.]]
                      ...

            We can confirm that backpropagation stops at `y3_unlinked`.
            Then let's see how to execute backpropagation to the root variable (`x`).
            Since it's a little bit complicated, let us give you an example of common pitfall first.
            **Note that this is an incorrect way and intended just to show the backward's behavior.**

            .. code-block:: python

                y3.backward()  # this works, but computed gradient values are not correct.
                print(nn.get_parameters()["conv1/conv/W"].g)

            Output :

            .. code-block:: plaintext

                [[[[ 17.795254    23.960905    25.51168   ]
                   [ 20.661646    28.484127    19.406212  ]
                   [ 26.91042     22.239697    23.395714  ]]
                                     ...

            **Note that this is a wrong result.** The gradient held by `y3_unlinked` has been totally ignored.
            As described above, just calling `backward`, the gradient (of the leaf variable where you call `backward`) is considered to be 1.

            To execute backpropagation over 2 separate graphs **correctly**,  We need to specify `grad=None` as shown below, then present gradient held by that variable is used for computation.
            (`y3.backward(grad=y3_unlinked.g)` does the same thing.)

            .. code-block:: python

                #reset all the gradient values.
                for v in nn.get_parameters().values():
                    v.g = 0.
                for v in [y0, y1, y2, y3, y4, y5]:
                    v.g = 0.  # need to reset all the gradient values.

                loss.backward()  # backpropagation starts from the leaf variable again.
                y3.backward(grad=None)  # By this, it can take over the gradient held by y3_unlinked.
                print(nn.get_parameters()["conv1/conv/W"].g)  # correct result.

            This time you should have the same result.

            .. code-block:: plaintext

                [[[[ 0.00539637  0.00770839  0.0090611 ]
                   [ 0.0078223   0.00978992  0.00720569]
                   [ 0.00879023  0.00578172  0.00790895]]
                                     ...


        """
        cdef NdArrayPtr p
        cdef cpp_bool clear_initial_grad = False
        if isinstance(grad, NdArray):
            # Share a user-refered NdArray as a initial grad
            clear_initial_grad = False
            p = ( < NdArray > grad).arr            
        else:
            # Use a temporary NdArray as a initial grad
            clear_initial_grad = True
            if grad is None:
                pass
            elif np.isscalar(grad):
                arr = NdArray(self.shape)
                arr.fill(grad)
                p = ( < NdArray > arr).arr
            elif isinstance(grad, np.ndarray):
                arr = NdArray(grad.shape)
                arr.data = grad
                p = ( < NdArray > arr).arr
            else:
                # Try to interpret as scalar value
                arr = NdArray()
                arr.data = grad
                p = ( < NdArray > arr).arr

        cdef vector[CommunicatorBackwardCallbackPtr] callback_list
        if type(communicator_callbacks) == list:
            for x in communicator_callbacks:
                callback_list.push_back((< CommunicatorBackwardCallback?> x).var)
        elif type(communicator_callbacks) != type(None):
            callback_list.push_back((< CommunicatorBackwardCallback?> communicator_callbacks).var)

        cdef function_hook_type function_pre_hook_c
        cdef function_hook_type function_post_hook_c

        if function_pre_hook is not None:
            function_pre_hook_c = create_function_hook_with_object(function_pre_hook)
        if function_post_hook is not None:
            function_post_hook_c = create_function_hook_with_object(function_post_hook)

        with nogil:
            self.get_varp_no_gil().backward(p, clear_buffer, callback_list, function_pre_hook_c, function_post_hook_c, clear_initial_grad)

    def unlinked(self, need_grad=None):
        """
        This function is `deprecated`, use get_unlinked_variable instead.
        """
        import nnabla as nn
        nn.logger.warning(
            "This function is `deprecated`, use get_unlinked_variable instead.")

        return self.get_unlinked_variable(need_grad)

    def get_unlinked_variable(self, need_grad=None):
        """
        Gets an unlinked (forgetting parent) variable that shares a Variable buffer
        instance.

        Args:
            need_grad (bool, optional):
                By default, the unlinked variable will have the same need_grad
                flag with this variable instance. By specifying a boolean value,
                the new need_grad flags will be set to the unlinked variable.
                It is recommended to explicitly specify this option to avoid an
                unintended behavior.

        Returns: :class:`~nnabla.Variable`


        Note:
            The unlinked Variable behaves equivalent to the original variable
            in a comparison operator and hash function regardless whether or
            not the `need_grad` attribute is changed.
            See a note in the `Variable` class documentation. Also, for backward execution with unlinked variable(s), please refer to `backward` and its example.

        Example:

            .. code-block:: python

                import numpy as np
                import nnabla as nn
                import nnabla.parametric_functions as PF

                x = nn.Variable.from_numpy_array(np.array([[1, 2], [3, 4]]))
                y = PF.affine(x, 4, name="y")

                # Create a new variable of which graph connection is unlinked.
                # Recommend to specify need_grad option explicitly .
                z = y.get_unlinked_variable(need_grad=False)

                print(y.parent)
                # Affine
                print(z.parent)  # z is unlinked from the parent x but shares the buffers of y.
                # None

        """
        var = Variable.create_from_cvariable(self.get_varp().variable())
        if need_grad is not None:
            var.need_grad = need_grad
        else:
            (< Variable > var).get_varp().set_need_grad(self.get_varp().need_grad_state())
        return var

    def no_grad(self):
        """No gradients for the whole network.

        This method is like :obj:`nnabla.no_grad` but can be used for the static network only, and useful for 
        the case where the network is loaded from NNP format.
        
        Example:

            .. code-block:: python

                x = nn.Variable.from_numpy_array([2, 3])
                y = <Network>(x).no_grad()
        """

        import nnabla.experimental.graph_converters as GC
        modifiers = [GC.NoGradModifier()]
        gc = GC.GraphConverter(modifiers)
        out = gc.convert(self)
        return out
        

    @property
    def persistent(self):
        """
        Returns the persistent flag of this variable. If True, the variable
        is not cleared even if clear options in
        :meth:`nnabla._variable.Variable.forward` and 
        :meth:`nnabla._variable.Variable.backward` are enabled.
        This is useful when you debug the variable values, or log them.
        This method can also be called as a setter.

        Args:
            b(bool)

        Returns: 
            bool

        """
        return self.get_varp().persistent()

    @persistent.setter
    def persistent(self, cpp_bool b):
        self.get_varp().set_persistent(b)

    @property
    def name(self):
        return self.get_varp().name()

    @name.setter
    def name(self, string name):
        self.get_varp().set_name(name)

    @property
    def rank(self, ):
        return self.get_varp().rank()

    def visit(self, f):
        """
        Visit functions recursively in forward order.

        Args:
            f (function): Function object which takes
                :obj:`nnabla._function.Function` object as an argument.

        Returns: 
            None

        Example:

            .. code-block:: python

                import nnabla as nn
                import nnabla.functions as F
                import nnabla.parametric_functions as PF

                # Define a simple network-graph
                def network_graph(x, maps=16, test=False):
                    h = x
                    h = PF.convolution(h, maps, kernel=(3, 3), pad=(1, 1), name="first-conv", with_bias=False)
                    h = F.average_pooling(h, h.shape[2:])
                    pred = PF.affine(h, 10, name="pred")
                    return pred

                # You can modify this PrintFunc to get the other information like inputs(nnabla_func.inputs), outputs and arguments(nnabla_func.info.args) of nnabla functions.
                class PrintFunc(object):
                    def __call__(self, nnabla_func):
                        print(nnabla_func.info.type_name)

                x = nn.Variable([1, 3, 16, 16])
                output = network_graph(x)
                output.visit(PrintFunc())

            Output :

            .. code-block:: plaintext

                Convolution
                AveragePooling
                Affine
        """
        def _recursive_visit_functions(func, seen):
            if func is None:
                return
            seen.add(func)
            for i in func.inputs:
                if i.parent in seen:
                    continue
                _recursive_visit_functions(i.parent, seen)
            f(func)
        seen = set()
        _recursive_visit_functions(self.parent, seen)

    def visit_check(self, f):
        """
        Visit functions recursively in forward order.

        Note:
            If any of evaluation of the function object returns True,
            the visit propagation will stop immediately,
            and will return True.

        Args:
            f (function): Function object which takes
                :obj:`nnabla._function.Function` object as an argument.

        Returns: 
            bool
            Returns True if any of the function object call returns True.

        Example:

            Define a simple network-graph where AveragePooling function can be added explicitly as below:

            .. code-block:: python

                def network_graph(x, add_avg_pool=False, maps=16, test=False):
                    h = x
                    h = PF.convolution(h, maps, kernel=(3, 3), pad=(1, 1), name="first-conv", with_bias=False)
                    if add_avg_pool :
                        h = F.average_pooling(h, h.shape[2:])
                    else :
                        h = F.relu(h)
                    pred = PF.affine(h, 10, name="pred")
                    return pred

                # Define 'PrintFunc()' to check whether "AveragePooling" function exists in the network-graph
                class PrintFunc(object):
                    def __call__(self, nnabla_func):
                        if nnabla_func.info.type_name =="AveragePooling" :
                            print("{} exists in the graph".format(nnabla_func.info.type_name))
                            return True
                        else :
                            return False

            Create a network-graph which has AveragePooling function and call visit_check() method :

            .. code-block:: python

                x = nn.Variable([1, 3, 16, 16])
                output = network_graph(x, add_avg_pool=True)  #Adding AveragePooling function to the graph
                print("The return value of visit_check() method is : {}".format(output.visit_check(PrintFunc())))

            Output :

            .. code-block:: plaintext

                AveragePooling exists in the graph
                The return value of visit_check() method is : True

            Create a network-graph which doesn't have AveragePooling function and call visit_check() method :

            .. code-block:: python

                nn.clear_parameters()                         # call this in case you want to run the following code again
                output = network_graph(x, add_avg_pool=False) # Exclusion of AveragePooling function in the graph
                print("The return value of visit_check() method is : {}".format(output.visit_check(PrintFunc())))

            Output :

            .. code-block:: plaintext

                The return value of visit_check() method is : False

        """

        def _recursive_visit_functions(func, seen):
            if func is None:
                return False
            seen.add(func)
            for i in func.inputs:
                if i.parent in seen:
                    continue
                if _recursive_visit_functions(i.parent, seen):
                    return True
            return f(func)

        seen = set()
        return _recursive_visit_functions(self.parent, seen)

    def clear_all_graph_links(self, ):
        """Clear all intermediate functions and variables.

        This method clear all intermediate functions and variables up to this variable 
        in forward pass and is useful for the truncated backpropagation through time 
        (truncated BPTT) in dynamic graph.
        """
        def _clear_all_graph_links(func):
            for v in func.outputs:
                v._clear_parent()
        self.visit(_clear_all_graph_links)

    def _clear_parent(self, ):
        self.get_varp().set_parent(< CgFunctionPtr?> NULL)

    def __pos__(self):
        return AOP.pos(self)

    def __neg__(self):
        return AOP.neg(self)

    def __add__(x, y):
        return AOP.add(x, y)

    def __sub__(x, y):
        return AOP.sub(x, y)

    def __mul__(x, y):
        return AOP.mul(x, y)

    def __truediv__(x, y):
        return AOP.truediv(x, y)

    def __div__(x, y):
        return AOP.div(x, y)

    def __pow__(x, y, z):
        return AOP.pow(x, y, z)

    def __matmul__(x, y):
        return AOP.matmul(x, y)

    def __radd__(y, x):
        return AOP.add(x, y)

    def __rsub__(y, x):
        return AOP.sub(x, y)

    def __rmul__(y, x):
        return AOP.mul(x, y)

    def __rtruediv__(y, x):
        return AOP.truediv(x, y)

    def __rdiv__(y, x):
        return AOP.div(x, y)

    def __rpow__(y, x, z):
        return AOP.pow(x, y, z)

    def __getitem__(self, key):
        return IDX.getitem(self, key)

    def __setitem__(self, key, value):
        if not isinstance(value, Variable):
            if isinstance(value, NdArray):
                value = Variable(value.shape).apply(data=value)
            else:
                value = Variable.from_numpy_array(value)
        var = self.get_unlinked_variable()
        if self.parent:
            var.apply(parent=self.parent)
        self.rewire_on(IDX.setitem(var, key, value))
