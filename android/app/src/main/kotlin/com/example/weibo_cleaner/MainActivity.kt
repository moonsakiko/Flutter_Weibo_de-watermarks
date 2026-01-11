package com.example.weibo_cleaner

import android.content.ContentValues
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.opencv.android.OpenCVLoader
import org.opencv.android.Utils
import org.opencv.core.Mat
import org.opencv.core.Rect
import org.opencv.imgproc.Imgproc
import org.tensorflow.lite.Interpreter
import org.tensorflow.lite.support.common.FileUtil
import org.tensorflow.lite.support.common.ops.NormalizeOp
import org.tensorflow.lite.support.image.ImageProcessor
import org.tensorflow.lite.support.image.TensorImage
import org.tensorflow.lite.support.image.ops.ResizeOp
import java.io.File
import kotlin.math.max
import kotlin.math.min

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.weibo_cleaner/processor"
    private var tflite: Interpreter? = null
    // YOLOv8 默认输入尺寸
    private val INPUT_SIZE = 640 

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        OpenCVLoader.initDebug()

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "processImages") {
                val tasks = call.argument<List<Map<String, String>>>("tasks") ?: listOf()
                val conf = call.argument<Double>("confidence")?.toFloat() ?: 0.5f
                val padding = call.argument<Double>("padding")?.toFloat() ?: 0.1f

                CoroutineScope(Dispatchers.IO).launch {
                    initModel()
                    var successCount = 0
                    
                    tasks.forEach { task ->
                        val wmPath = task["wm"]!!
                        val cleanPath = task["clean"]!!
                        if (processOne(wmPath, cleanPath, conf, padding)) {
                            successCount++
                        }
                    }

                    withContext(Dispatchers.Main) {
                        result.success(mapOf("count" to successCount))
                    }
                }
            }
        }
    }

    private fun initModel() {
        if (tflite == null) {
            val modelFile = FileUtil.loadMappedFile(context, "yolov8_wm.tflite") // 对应转换后的文件名
            val options = Interpreter.Options()
            tflite = Interpreter(modelFile, options)
        }
    }

    private fun processOne(wmPath: String, origPath: String, conf: Float, pad: Float): Boolean {
        try {
            // 1. 加载图片
            val wmBitmap = BitmapFactory.decodeFile(wmPath) ?: return false
            val origBitmap = BitmapFactory.decodeFile(origPath) ?: return false

            // 2. YOLO 预处理
            val imageProcessor = ImageProcessor.Builder()
                .add(ResizeOp(INPUT_SIZE, INPUT_SIZE, ResizeOp.ResizeMethod.BILINEAR))
                .add(NormalizeOp(0f, 255f)) // YOLOv8 需要归一化到 0-1
                .build()
            var tImage = TensorImage.fromBitmap(wmBitmap)
            tImage = imageProcessor.process(tImage)

            // 3. 推理
            // YOLOv8 输出通常是 [1, 5, 8400] (xywh + conf)
            // 有些导出可能是 [1, 8400, 5]，需要判断形状
            val outputTensor = tflite!!.getOutputTensor(0)
            val shape = outputTensor.shape() // e.g. [1, 5, 8400]
            
            // 准备接收数组
            // 假设是 [1, 5, 8400] 的情况
            val outputs = Array(1) { Array(shape[1]) { FloatArray(shape[2]) } }
            tflite!!.run(tImage.buffer, outputs)

            // 4. 解析输出找到最佳框
            val box = parseYoloOutput(outputs[0], conf, wmBitmap.width, wmBitmap.height, pad) 
                ?: return false // 没找到水印

            // 5. OpenCV 修复
            return repairImage(wmBitmap, origBitmap, box, wmPath)

        } catch (e: Exception) {
            e.printStackTrace()
            return false
        }
    }

    // 解析 [5, 8400] 的 YOLO 输出
    private fun parseYoloOutput(data: Array<FloatArray>, confThresh: Float, imgW: Int, imgH: Int, pad: Float): Rect? {
        // data[0..3] 是 x,y,w,h (中心点坐标)
        // data[4] 是 置信度
        // 维度检查：如果是 [8400, 5] 需要转置逻辑，这里假设是 [5, 8400]
        val numProposals = data[0].size // 8400
        
        var maxConf = 0f
        var bestIdx = -1

        for (i in 0 until numProposals) {
            val confidence = data[4][i]
            if (confidence > maxConf) {
                maxConf = confidence
                bestIdx = i
            }
        }

        if (maxConf < confThresh) return null

        // 提取坐标 (归一化后的中心点 xywh)
        val cx = data[0][bestIdx]
        val cy = data[1][bestIdx]
        val w = data[2][bestIdx]
        val h = data[3][bestIdx]

        // 还原到原图尺寸
        // YOLO输出是基于 640x640 的，需要映射回 imgW x imgH
        val xFactor = imgW.toFloat() / INPUT_SIZE
        val yFactor = imgH.toFloat() / INPUT_SIZE

        val boxX = (cx - w / 2) * xFactor
        val boxY = (cy - h / 2) * yFactor
        val boxW = w * xFactor
        val boxH = h * yFactor

        // 应用 Padding (区域扩大)
        val padW = boxW * pad
        val padH = boxH * pad

        val rectX = (boxX - padW).toInt()
        val rectY = (boxY - padH).toInt()
        val rectW = (boxW + padW * 2).toInt()
        val rectH = (boxH + padH * 2).toInt()

        return Rect(rectX, rectY, rectW, rectH)
    }

    private fun repairImage(wmBm: Bitmap, origBm: Bitmap, rect: Rect, pathName: String): Boolean {
        // 使用 OpenCV 覆盖
        val wmMat = Mat()
        val origMat = Mat()
        Utils.bitmapToMat(wmBm, wmMat)
        Utils.bitmapToMat(origBm, origMat)

        // 对齐尺寸 (原图可能和水印图有细微差别，强行对齐)
        Imgproc.resize(origMat, origMat, wmMat.size())

        // 边界检查 (Clamping)
        val x1 = max(0, rect.x)
        val y1 = max(0, rect.y)
        val x2 = min(wmMat.cols(), rect.x + rect.width)
        val y2 = min(wmMat.rows(), rect.y + rect.height)

        if (x2 <= x1 || y2 <= y1) return false

        val safeRect = Rect(x1, y1, x2 - x1, y2 - y1)

        // 核心操作：剪切原图区域 -> 覆盖水印图区域
        val patch = origMat.submat(safeRect)
        patch.copyTo(wmMat.submat(safeRect))

        // 保存结果
        val resultBm = Bitmap.createBitmap(wmMat.cols(), wmMat.rows(), Bitmap.Config.ARGB_8888)
        Utils.matToBitmap(wmMat, resultBm)
        
        saveToGallery(resultBm, "WeiboCleaned", "Fixed_${File(pathName).name}")
        return true
    }

    private fun saveToGallery(bm: Bitmap, folder: String, name: String) {
        val cv = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg")
            put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/$folder")
        }
        val uri = context.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, cv)
        uri?.let {
            context.contentResolver.openOutputStream(it)?.use { out ->
                bm.compress(Bitmap.CompressFormat.JPEG, 95, out)
            }
        }
    }
}