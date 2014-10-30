'''
TODO:

GL Backend and functions
[x] make gl.h pxd file
[x] implement shader based lines and points in gl backend
[x] add render to texture option if nessesay

GL Fonts:
[x] Select GL Font Lib : https://github.com/memononen/fontstash
[x] Write cython binding
[x] use in this lib

UI features
[ ] implement selector box
[x] implement toggle / switch
[x] make menu move resize and minimize fn selectable and lockalbe in x or y
[ ] design the UI and implement using gl calls above
[ ] Optional: Add global UI scale option
[x] Implement Perf graph in cython
[x] Implement scrolling

Done:
UI interaction
UI layouting
UI value syncing

'''


from cygl cimport cgl as gl
from cygl cimport utils
from pyfontstash cimport pyfontstash as fs

include 'gldraw.pxi'
include 'helpers.pxi'

#global init of gl fonts
cdef fs.Context glfont = fs.Context()
glfont.add_font('roboto', 'Roboto-Regular.ttf')




cdef class UI:
    '''
    The UI context for a glfw window.
    '''
    cdef Input new_input
    cdef bint should_redraw
    cdef public list elements
    cdef FitBox window

    cdef fbo_tex_id ui_layer

    def __cinit__(self):
        self.elements = []
        self.new_input = Input()
        self.window = FitBox(Vec2(0,0),Vec2(0,0))
        self.ui_layer = create_ui_texture(Vec2(200,200))

    def __init__(self):
        self.should_redraw = True


    def update_mouse(self,mx,my):
        if self.window.mouse_over(Vec2(mx,my)):
            self.new_input.dm.x,self.new_input.dm.y = mx-self.new_input.m.x, my-self.new_input.m.y
            self.new_input.m.x,self.new_input.m.y = mx,my


    def update_window(self,w,h):
        global should_redraw
        should_redraw = True
        self.window.size.x,self.window.size.y = w,h
        gl.glScissor(0,0,int(w),int(h))
        resize_ui_texture(self.ui_layer,self.window.size)


    def update_scroll(self, sx,sy):
        self.new_input.s.x = sx
        self.new_input.s.y = sy

    def update_key(self, key, scancode, action, mods):
        self.new_input.keys.append((key,scancode,action,mods))

    def update_char(self,c):
        self.new_input.chars.append(chr(c))

    def update_button(self,button,action,mods):
        self.new_input.buttons.append((button,action,mods))

    cdef sync(self):
        for e in self.elements:
            e.sync()

    cdef handle_input(self):
        if self.new_input:
            #print self.new_input
            for e in self.elements:
                e.handle_input(self.new_input,True)
            self.new_input.purge()

    cdef draw(self):
        global should_redraw
        global window_size
        window_size = self.window.size

        if should_redraw:
            render_to_ui_texture(self.ui_layer)
            gl.glPushMatrix()
            adjust_view(self.window.size)

            glfont.clear_state()
            glfont.set_size(18)
            glfont.set_color_float(1,1,1,1)
            glfont.set_align(fs.FONS_ALIGN_TOP)

            for e in self.elements:
                e.draw(self.window,nested=False)


            gl.glPopMatrix()
            render_to_screen()

            should_redraw = False

        draw_ui_texture(self.ui_layer)


    def update(self):
        global should_redraw
        self.handle_input()
        self.sync()
        self.draw()

include 'menus.pxi'
include 'ui_elements.pxi'

#below are classes used by menu and ui_elements.

cdef class UI_element:
    '''
    The base class for all UI elements.
    '''
    cdef readonly bytes label
    cdef readonly long  uid
    cdef public FitBox outline

    cpdef sync(self):
        global should_redraw
        pass

    cpdef draw(self,FitBox context, bint nested=True):
        pass

    cpdef handle_input(self,Input new_input,bint visible):
        global should_redraw
        pass

    property height:
        def __get__(self):
            raise Exception("Please implement in derived class.")

cdef class Synced_Value:
    '''
    an element that has a synced value
    '''
    cdef object attribute_context
    cdef bytes attribute_name
    cdef object _value
    cdef object getter
    cdef object setter

    def __cinit__(self,bytes attribute_name, object attribute_context,getter=None,setter=None):
        self.attribute_context = attribute_context
        self.attribute_name = attribute_name
        self.getter = getter
        self.setter = setter

    def __init__(self,bytes attribute_name, object attribute_context,getter=None,setter=None):
        self.sync()


    cdef sync(self):
        if self.getter:
            val = self.getter()
            if val != self._value:
                self._value = val
                global should_redraw
                should_redraw = True

        elif self._value != self.attribute_context.__dict__[self.attribute_name]:
            self._value = self.attribute_context.__dict__[self.attribute_name]
            global should_redraw
            should_redraw = True


    property value:
        def __get__(self):
            return self._value
        def __set__(self,val):
            #conserve the type
            t = type(self._value)
            self._value = t(val)

            if self.setter:
                self.setter(self._value)

            self.attribute_context.__dict__[self.attribute_name] = self._value


cdef class Input:
    '''
    Holds accumulated user input collect during a frame.
    '''

    cdef public list keys,chars,buttons
    cdef Vec2 dm,m,s

    def __cinit__(self):
        self.keys = []
        self.buttons = []
        self.chars = []
        self.m = Vec2(0,0)
        self.dm = Vec2(0,0)
        self.s = Vec2(0,0)

    def __init__(self):
        pass

    def __nonzero__(self):
        return bool(self.keys or self.chars or self.buttons or self.dm or self.s)

    def purge(self):
        self.keys = []
        self.buttons = []
        self.chars = []
        self.dm.x = 0
        self.dm.y = 0
        self.s.x = 0
        self.s.y = 0

    def __repr__(self):
        return 'Current Input: \n   Mouse pos  : %s\n   Mouse delta: %s\n   Scroll: %s\n   Buttons: %s\n   Keys: %s\n   Chars: %s' %(self.m,self.dm,self.s,self.buttons,self.keys,self.chars)


cdef class Draggable:
    '''
    A rectangle that can be dragged.
    Does not move itself but the drag vector is added to 'value'
    '''
    cdef FitBox outline
    cdef Vec2 touch_point,drag_accumulator
    cdef bint selected,zero_crossing,dragged
    cdef Vec2 value
    cdef int arrest_axis
    cdef object click_cb

    def __cinit__(self,Vec2 pos, Vec2 size, Vec2 value, arrest_axis = 0,zero_crossing=True,click_cb = None):
        self.outline = FitBox(pos,size)
        self.value = value
        self.selected = False
        self.touch_point = Vec2(0,0)
        self.drag_accumulator = Vec2(0,0)

        self.arrest_axis = arrest_axis
        self.zero_crossing = zero_crossing
        self.click_cb = click_cb
        self.dragged = False

    def __init__(self,Vec2 pos, Vec2 size, Vec2 value, arrest_axis = 0,zero_crossing=True,click_cb = None):
        pass

    cdef draw(self, FitBox parent_size,bint nested=True):
        self.outline.compute(parent_size)
        self.outline.sketch()

    cdef handle_input(self,Input new_input, bint visible):
        global should_redraw
        if self.selected and new_input.dm:
            self.value -= self.drag_accumulator
            self.drag_accumulator = new_input.m-self.touch_point
            if self.drag_accumulator.x < 2 or self.drag_accumulator.y  < 2:
                self.dragged  = True

            if self.arrest_axis == 1:
                self.drag_accumulator.x = 0
            elif self.arrest_axis == 2:
                self.drag_accumulator.y = 0

            if not self.zero_crossing:
                if self.value.x > 0 and self.value.x + self.drag_accumulator.x <= 0:
                    self.drag_accumulator.x = .001 - self.value.x
                elif self.value.x < 0 and self.value.x + self.drag_accumulator.x >= 0:
                    self.drag_accumulator.x = -.001 - self.value.x
                elif self.value.x ==0:
                    self.drag_accumulator.x = 0
                if self.value.y > 0 and self.value.y + self.drag_accumulator.y <= 0:
                    self.drag_accumulator.y = .001 - self.value.y
                elif self.value.y < 0 and self.value.y + self.drag_accumulator.y >= 0:
                    self.drag_accumulator.y = -.001 - self.value.y
                elif self.value.y ==0:
                    self.drag_accumulator.y = 0

            self.value += self.drag_accumulator

            should_redraw = True

        for b in new_input.buttons:
            if b[1] == 1 and visible:
                if self.outline.mouse_over(new_input.m):
                    self.selected = True
                    self.dragged  = False
                    new_input.buttons.remove(b)
                    self.touch_point.x = new_input.m.x
                    self.touch_point.y = new_input.m.y
                    self.drag_accumulator = Vec2(0,0)
            if self.selected and b[1] == 0:
                self.selected = False
                if self.click_cb and not self.dragged:
                    self.click_cb()

    cdef sync(self):
        pass

cdef class FitBox:
    '''
    A box that will fit itself into a context.
    Specified by rules for x and y respectively:
        size positive -> size from self.org
        size 0 -> span into parent context and lock it like this. If you want it draggable use -.001 or .001
        size negative -> make the box to up to size pixels to the parent container.
        position negative -> align to the opposite side of context
        position 0  -> span into parent context and lock it like this. If you want it draggable use -.001 or .001

    This is quite expressive but does have a limitation:
        You cannot design a box that is outside of the parent context.

    Its made of 4 Vec2
        "design_org" "design_size" define the rules for placement and size

        "org" and "size" are the computed results of the box
            fitted and translated by its parent context

    Vec2 min_size is optional.
    '''
    cdef Vec2 design_org,org,design_size,size,min_size

    def __cinit__(self,Vec2 position,Vec2 size, Vec2 min_size = Vec2(0,0)):
        self.design_org = Vec2(position.x,position.y)
        self.design_size = Vec2(size.x,size.y)
        # The values below are just temporay
        # and will be overwritten by compute.
        self.org = Vec2(position.x,position.y)
        self.size = Vec2(size.x,size.y)
        self.min_size = Vec2(min_size.x,min_size.y)


    def __init__(self,Vec2 position,Vec2 size, Vec2 min_size = Vec2(0,0)):
        pass

    cdef collapse(self):

        #object is positioned from left(resp. top) and sized from object org
        if self.design_org.x >= 0 and  self.design_size.x  > 0:
            self.design_size.x = self.min_size.x
        #object is positioned from right (resp. bottom) and sized from context size
        elif self.design_org.x < 0 and self.design_size.x <= 0:
            self.design_org.x = self.design_size.x - self.min_size.x
            #self.design_size.x = self.min_size.x
        #object is positioned from left (top) and sized from context size:
        elif self.design_org.x >= 0 and self.design_size.x <= 0:
            pass
        #object is positioned from right and sized from object org
        elif self.design_org.x < 0 and self.design_size.x > 0:
            self.design_size.x = self.min_size.x
        else:
            pass

        #object is positioned from left(resp. top) and sized from object org
        if self.design_org.y >= 0 and self.design_size.y  > 0:
            self.design_size.y = self.min_size.y
        #object is positions from right (resp. bottom) and sized from context size
        elif self.design_org.y < 0 and self.design_size.y <= 0:
            self.design_org.y = self.design_size.y -self.min_size.y
            #self.design_size.y = self.min_size.y
        #object is positioned from left (top) and sized from context size:
        elif self.design_org.y >= 0 and self.design_size.y <= 0:
            pass
        #object is positioned from right and sized from object org
        elif self.design_org.y < 0 and self.design_size.y > 0:
            self.design_size.y = self.min_size.y
        else:
            pass


    cdef inflate(self,FitBox target):

        #object is positioned from left(resp. top) and sized from object org
        if self.design_org.x >= 0 and  self.design_size.x  > 0:
            self.design_size.x = target.design_size.x
        #object is positioned from right (resp. bottom) and sized from context size
        elif self.design_org.x < 0 and self.design_size.x <= 0:
            self.design_org.x = target.design_org.x
            #self.design_size.x = self.min_size.x
        #object is positioned from left (top) and sized from context size:
        elif self.design_org.x >= 0 and self.design_size.x <= 0:
            pass
        #object is positioned from right and sized from object org
        elif self.design_org.x < 0 and self.design_size.x > 0:
            self.design_size.x = target.design_size.x
        else:
            pass

        #object is positioned from left(resp. top) and sized from object org
        if self.design_org.y >= 0 and  self.design_size.y  > 0:
            self.design_size.y = target.design_size.y
        #object is positioned from right (resp. bottom) and sized from context size
        elif self.design_org.y < 0 and self.design_size.y <= 0:
            self.design_org.y = target.design_org.y
            #self.design_size.y = self.min_size.y
        #object is positioned from left (top) and sized from context size:
        elif self.design_org.y >= 0 and self.design_size.y <= 0:
            pass
        #object is positioned from right and sized from object org
        elif self.design_org.y < 0 and self.design_size.y > 0:
            self.design_size.y = target.design_size.y
        else:
            pass


    cdef is_collapsed(self,float slack = 30):
        cdef FitBox collapser = self.copy()
        collapser.collapse()
        return slack >= self.design_distance(collapser)



    cdef compute(self,FitBox context):

        # all x
        if self.design_org.x >=0:
            self.org.x = self.design_org.x
        else:
            self.org.x = context.size.x+self.design_org.x #design org is negative - double subtraction
        if self.design_size.x > 0:
            # size is direcly specified
            self.size.x = self.design_size.x
        else:
            self.size.x = context.size.x - self.org.x + self.design_size.x #design size is negative - double subtraction

        self.size.x = max(self.min_size.x,self.size.x)
        # finally translate into scene by parent org
        self.org.x +=context.org.x


        if self.design_org.y >=0:
            self.org.y = self.design_org.y
        else:
            self.org.y = context.size.y+self.design_org.y #design size is negative - double subtraction
        if self.design_size.y > 0:
            # size is direcly specified
            self.size.y = self.design_size.y
        else:
            self.size.y = context.size.y - self.org.y + self.design_size.y #design size is negative - double subtraction


        self.size.y = max(self.min_size.y,self.size.y)
        # finally translate into scene by parent org
        self.org.y +=context.org.y


    property rect:
        def __get__(self):
            return self.org.x,self.org.y,self.size.x,self.size.y

    property ellipse:
        def __get__(self):
            return self.org.x+self.size.x/2,self.org.y+self.size.y/2, self.size.x,self.size.y

    property center:
        def __get__(self):
            return self.org.x+self.size.x/2,self.org.y+self.size.y/2

    cdef bint mouse_over(self,Vec2 m):
        return self.org.x <= m.x <= self.org.x+self.size.x and self.org.y <= m.y <=self.org.y+self.size.y

    def __repr__(self):
        return "FitBox:\n   design org: %s size: %s\n   comptd org: %s size: %s"%(self.design_org,self.design_size,self.org,self.size)

    cdef same_design(self,FitBox other):
        return bool(self.design_org == other.design_org and self.design_size == other.design_size)

    cdef design_distance(self,FitBox other):
        cdef float d = 0
        d += abs(self.design_size.x-other.design_size.x)
        d += abs(self.design_size.y-other.design_size.y)
        d += abs(self.design_org.x-other.design_org.x)
        d += abs(self.design_org.y-other.design_org.y)
        return d

    cdef sketch(self):
        rect(self.org,self.size)

    cdef copy(self):
        return FitBox( Vec2(*self.design_org), Vec2(*self.design_size), Vec2(*self.min_size) )


cdef class Vec2:
    #cdef public float x,y declared in pyglui.pxd

    def __cinit__(self,float x, float y):
        self.x = x
        self.y = y

    def __init__(self,x,y):
        pass

    def __nonzero__(self):
        return bool(self.x or self.y)

    def __add__(self,Vec2 other):
        return Vec2(self.x+other.x,self.y+other.y)

    def __iadd__(self,Vec2 other):
        self.x +=other.x
        self.y += other.y
        return self

    def __sub__(self,Vec2 other):
        return Vec2(self.x-other.x,self.y-other.y)

    def __isub__(self,Vec2 other):
        self.x -=other.x
        self.y -= other.y
        return self

    def __repr__(self):
        return 'x: %s y: %s'%(self.x,self.y)

    def __richcmp__(self,Vec2 other,int op):
        '''
        <   0
        ==  2
        >   4
        <=  1
        !=  3
        >=  5
        '''
        if op == 2:
            return bool(self.x == other.x and self.y == other.y)
        else:
            return NotImplemented


    def __getitem__(self,idx):
        if idx==0:
            return self.x
        if idx==1:
            return self.y
        raise IndexError()

    def as_tuple(self):
       return self.x,self.y

    def from_tuple(self,val):
        self.x,self.y = val
