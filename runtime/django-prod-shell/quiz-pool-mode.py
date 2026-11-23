from nkb_exam.models import Exam, ExamConfig, ExamQuestionPoolConfig, ExamQuestion

ids = [
    "0fe081b6-f243-4def-8688-0054ed79d1f9",
    "b4ec581f-6622-46b8-82eb-c4ecfb266212",
]

for quiz_id in ids:
    exam = Exam.objects.filter(id=quiz_id).first()
    print("---")
    print("quiz_id", quiz_id)
    if not exam:
        print("status MISSING")
        continue
    print("title", exam.title)
    print("questions_picking_type", exam.questions_picking_type)
    print("question_jumbling", exam.question_jumbling)
    config = ExamConfig.objects.filter(exam_id=quiz_id).first()
    pool = (
        ExamQuestionPoolConfig.objects.filter(exam_config=config).first()
        if config
        else None
    )
    print("question_pool_picking_mode", getattr(pool, "question_pool_picking_mode", None))
    print("total_no_of_questions", getattr(pool, "total_no_of_questions", None))
    print("attached_question_count", ExamQuestion.objects.filter(exam_id=quiz_id).count())
