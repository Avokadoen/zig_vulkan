
TODO:

[ ] update host main pipeline
[ ] panic if max sets < 8
[ ] track total t_value (we reset it in scatter for now for correct position)

[ ] indirect dispatch

split hit record into multiple buffers:
 - Some order should be persistent, but maybe some can be lookup based? (not moved when sorting)
 - look into storageBuffer16BitAccess int16
https://developer.download.nvidia.com/video/gputechconf/gtc/2020/presentations/s21572-a-faster-radix-sort-implementation.pdf
https://web.archive.org/web/20210709113817/http://www.heterogeneouscompute.org/wordpress/wp-content/uploads/2011/06/RadixSort.pdf


[ ] draw run every loop (on a different queue?)
[ ] miss should maybe run on the same queue as draw
