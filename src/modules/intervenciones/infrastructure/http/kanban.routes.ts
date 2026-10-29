import { Router } from 'express';
import { getKanbanBoard, moveKanbanTask } from './kanban.controller';

const router = Router();
router.get('/', getKanbanBoard);
router.patch('/:id/move', moveKanbanTask);
export default router;