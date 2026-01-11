package com.example.weibo_cleaner

import android.content.ContentValues
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
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
import java.io.FileOutputStream
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.weibo_cleaner/processor"
    private var tflite: Interpreter? = null
    private val INPUT_SIZE = 640 

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        OpenCVLoader.initDebug()

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "processImages") {
                val tasks = call.argument<List<Map<String, String>>>("tasks") ?: listOf()
                val confThreshold = call.argument<Double>("confidence")?.toFloat() ?: 0.4f
                val paddingRatio = call.argument<Double>("padding")?.toFloat() ?: 0.1f
                
                CoroutineScope(Dispatchers.IO).launch {
                    val logs = StringBuilder()
                    var successCount = 0
                    
                    try {
                        if (tflite == null) {
                            logs.append("Load Model...\n")
                            val modelFile = FileUtil.loadMappedFile(context, "yolov8_wm.tflite")
                            tflite = Interpreter(modelFile)
                            logs.append("Model Loaded.\n")
                        }
                        
                        tasks.forEach { task ->
                            val wmPath = task["wm"]!!
                            val cleanPath = task["clean"]!!
                            val res = processOneImage(wmPath, cleanPath, confThreshold, paddingRatio, logs)
                            if (res) successCount++
                        }
                    } catch (e: Exception) {
                        logs.append("Critical Error: ${e.message}\n")
                    }

                    withContext(Dispatchers.Main) {
                        result.success(mapOf("count" to successCount, "logs" to logs.toString()))
                    }
                }
            }
        }
    }

    private fun processOneImage(wmPath: String, cleanPath: String, confThreshold: Float, paddingRatio: Float, logs: StringBuilder): Boolean {
        try {
            val wmBitmap = BitmapFactory.decodeFile(wmPath) ?: return false
            val cleanBitmap = BitmapFactory.decodeFile(cleanPath) ?: return false

            val imageProcessor = ImageProcessor.Builder()
                .add(ResizeOp(INPUT_SIZE, INPUT_SIZE, ResizeOp.ResizeMethod.BILINEAR))
                .add(NormalizeOp(0f, 255f)) // ⚠️ 关键：LOFTER 用的就是这个
                .build()
            var tImage = TensorImage.fromBitmap(wmBitmap)
            tImage = imageProcessor.process(tImage)

            val outputTensor = tflite!!.getOutputTensor(0)
            val outputShape = outputTensor.shape() 
            // 自动判断维度
            val dim1 = outputShape[1]
            val dim2 = outputShape[2]
            val outputArray = Array(1) { Array(dim1) { FloatArray(dim2) } }
            
            tflite!!.run(tImage.buffer, outputArray)

            // 尝试两种解析方式
            var bestBox: Rect? = null
            if (dim1 > dim2) {
                 bestBox = parseOutputTransposed(outputArray[0], confThreshold, wmBitmap.width, wmBitmap.height, paddingRatio)
            } else {
                 bestBox = parseOutputStandard(outputArray[0], confThreshold, wmBitmap.width, wmBitmap.height, paddingRatio)
            }

            if (bestBox != null) {
                logs.append("Target Found: $bestBox\n")
                repairWithOpenCV(wmBitmap, cleanBitmap, bestBox, wmPath)
                return true
            } else {
                logs.append("No watermark found (Max Conf < $confThreshold)\n")
                return false
            }
        } catch (e: Exception) {
            logs.append("Err processing ${File(wmPath).name}: ${e.message}\n")
            return false
        }
    }

    // --- 标准解析 (5, 8400) ---
    private fun parseOutputStandard(rows: Array<FloatArray>, confThresh: Float, imgW: Int, imgH: Int, pad: Float): Rect? {
        val numAnchors = rows[0].size 
        var maxConf = 0f
        var bestIdx = -1
        // data[4] 是置信度
        for (i in 0 until numAnchors) {
            val conf = rows[4][i] 
            if (conf > maxConf) { maxConf = conf; bestIdx = i }
        }
        if (maxConf < confThresh) return null
        return convertToRect(rows[0][bestIdx], rows[1][bestIdx], rows[2][bestIdx], rows[3][bestIdx], imgW, imgH, pad)
    }

    // --- 转置解析 (8400, 5) ---
    private fun parseOutputTransposed(rows: Array<FloatArray>, confThresh: Float, imgW: Int, imgH: Int, pad: Float): Rect? {
        var maxConf = 0f
        var bestIdx = -1
        // row[i][4] 是置信度
        for (i in rows.indices) {
            val conf = rows[i][4] 
            if (conf > maxConf) { maxConf = conf; bestIdx = i }
        }
        if (maxConf < confThresh) return null
        return convertToRect(rows[bestIdx][0], rows[bestIdx][1], rows[bestIdx][2], rows[bestIdx][3], imgW, imgH, pad)
    }

    private fun convertToRect(cx: Float, cy: Float, w: Float, h: Float, imgW: Int, imgH: Int, paddingRatio: Float): Rect {
        val isNormalized = w < 1.0f 
        val normCx = if (isNormalized) cx * INPUT_SIZE else cx
        val normCy = if (isNormalized) cy * INPUT_SIZE else cy
        val normW = if (isNormalized) w * INPUT_SIZE else w
        val normH = if (isNormalized) h * INPUT_SIZE else h

        val scaleX = imgW.toFloat() / INPUT_SIZE
        val scaleY = imgH.toFloat() / INPUT_SIZE
        
        val width = normW * scaleX
        val height = normH * scaleY
        // 中心点转左上角
        val x = (normCx * scaleX) - (width / 2)
        val y = (normCy * scaleY) - (height / 2)

        val paddingW = width * paddingRatio
        val paddingH = height * paddingRatio

        return Rect(
            (x - paddingW).roundToInt(),
            (y - paddingH).roundToInt(),
            (width + paddingW * 2).roundToInt(),
            (height + paddingH * 2).roundToInt()
        )
    }

    private fun repairWithOpenCV(wmBm: Bitmap, cleanBm: Bitmap, rect: Rect, originalPath: String) {
        val wmMat = Mat()
        val cleanMat = Mat()
        Utils.bitmapToMat(wmBm, wmMat)
        Utils.bitmapToMat(cleanBm, cleanMat)
        
        Imgproc.resize(cleanMat, cleanMat, wmMat.size())
        
        val x1 = rect.x.coerceIn(0, wmMat.cols() - 1)
        val y1 = rect.y.coerceIn(0, wmMat.rows() - 1)
        val x2 = (rect.x + rect.width).coerceIn(x1 + 1, wmMat.cols())
        val y2 = (rect.y + rect.height).coerceIn(y1 + 1, wmMat.rows())
        
        val safeRect = Rect(x1, y1, x2 - x1, y2 - y1)
        cleanMat.submat(safeRect).copyTo(wmMat.submat(safeRect))
        
        val resultBm = Bitmap.createBitmap(wmMat.cols(), wmMat.rows(), Bitmap.Config.ARGB_8888)
        Utils.matToBitmap(wmMat, resultBm)
        
        saveToGallery(resultBm, "Fixed_${File(originalPath).name}")
    }

    private fun saveToGallery(bm: Bitmap, fileName: String) {
        val cv = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
            put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg")
            put(MediaStore.MediaColumns.RELATIVE_PATH, "Pictures/WeiboCleaner")
        }
        context.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, cv)?.let { uri ->
            context.contentResolver.openOutputStream(uri)?.use { out ->
                bm.compress(Bitmap.CompressFormat.JPEG, 98, out)
            }
        }
    }
}