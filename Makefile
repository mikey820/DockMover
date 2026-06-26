TARGET := iphone:clang:14.5:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DockMover

DockMover_FILES = Tweak.x
DockMover_CFLAGS = -fobjc-arc -DDOCKMOVER_VERIFY
DockMover_FRAMEWORKS = UIKit

include $(THEOS)/makefiles/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"
